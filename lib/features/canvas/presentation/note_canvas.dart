import 'dart:math';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_note/core/constants/app_constants.dart';
import 'package:open_note/core/theme/app_colors.dart';
import 'package:open_note/features/canvas/controllers/canvas_controller.dart';
import 'package:open_note/features/canvas/controllers/rich_text_editing_controller.dart';
import 'package:open_note/features/canvas/models/note_text_box.dart';
import 'package:open_note/features/canvas/models/stroke_point.dart';
import 'package:open_note/features/canvas/models/tool_type.dart';
import 'package:open_note/features/canvas/presentation/painters/active_stroke_painter.dart';
import 'package:open_note/features/canvas/presentation/painters/completed_strokes_painter.dart';
import 'package:open_note/features/canvas/presentation/painters/eraser_cursor_painter.dart';
import 'package:open_note/features/canvas/presentation/painters/infinite_background_painter.dart';
import 'package:open_note/features/canvas/presentation/painters/lasso_path_painter.dart';
import 'package:open_note/features/canvas/presentation/painters/page_background_painter.dart';
import 'package:open_note/features/canvas/presentation/painters/selection_painter.dart';
import 'package:open_note/features/canvas/presentation/widgets/drawing_toolbar.dart';
import 'package:open_note/features/canvas/presentation/widgets/note_image_widget.dart';
import 'package:open_note/features/canvas/presentation/widgets/selection_toolbar.dart';
import 'package:open_note/features/canvas/presentation/widgets/text_box_widget.dart';
import 'package:open_note/features/canvas/presentation/widgets/unbounded_hit_test.dart';
import 'package:open_note/features/canvas/services/lasso_service.dart';

enum OffScreenDirection {
  above,
  below,
  left,
  right,
  none,
}

class NoteCanvas extends StatefulWidget {
  final CanvasController controller;
  final PageTemplate template;

  const NoteCanvas({
    super.key,
    required this.controller,
    this.template = PageTemplate.ruled,
  });

  @override
  State<NoteCanvas> createState() => _NoteCanvasState();
}

class _NoteCanvasState extends State<NoteCanvas>
    with SingleTickerProviderStateMixin {
  final TransformationController _transformationController =
      TransformationController();
  final Map<String, RichTextEditingController> _textControllers = {};

  final Map<int, Offset> _activePointers = {};
  int? _primaryDrawingPointer;
  PointerDeviceKind? _primaryPointerKind;
  bool _isPinching = false;
  double _initialPinchDistance = 0.0;
  Offset _initialPinchFocal = Offset.zero;
  Matrix4 _initialPinchMatrix = Matrix4.identity();

  static double _getScale(Matrix4 matrix) {
    final sx = matrix.storage[0];
    final sy = matrix.storage[1];
    return sqrt(sx * sx + sy * sy);
  }

  static double _getBaseScale(double viewportWidth) {
    if (viewportWidth <= 0) return 1.0;
    if (viewportWidth < AppConstants.defaultPageSize.width) {
      return viewportWidth / AppConstants.defaultPageSize.width;
    }
    return 1.0;
  }

  late final AnimationController _animController;
  Animation<Matrix4>? _matrixAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _animController.addListener(() {
      if (_matrixAnimation != null) {
        _transformationController.value = _matrixAnimation!.value;
      }
    });

    _transformationController.addListener(_onTransformationChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _centerCanvasInViewport();
      }
    });
  }

  void _onTransformationChanged() {
    final scale = _getScale(_transformationController.value);
    widget.controller.setCanvasScale(scale);
  }

  Matrix4 _clampTransformation(Matrix4 matrix, Size viewportSize) {
    if (viewportSize.width <= 0 || viewportSize.height <= 0) return matrix;

    final baseScale = _getBaseScale(viewportSize.width);
    final minScale = AppConstants.minScale * baseScale;
    final maxScale = AppConstants.maxScale * baseScale;

    final currentScale = _getScale(matrix);
    final scale = currentScale.clamp(minScale, maxScale);

    if (widget.controller.isInfinite) {
      final result = matrix.clone();
      if ((scale - currentScale).abs() > 0.0001) {
        final factor = scale / currentScale;
        result.storage[0] *= factor;
        result.storage[5] *= factor;
      }

      // OneNote-style top-left boundary:
      // Stops scrolling endlessly up and left into negative coordinates,
      // while allowing completely unbounded panning down (+Y) and right (+X).
      const maxTy = 40.0;
      final maxTx = max(
        40.0,
        (viewportSize.width - scale * AppConstants.defaultPageSize.width) / 2.0,
      );

      final tx = matrix.storage[12];
      final ty = matrix.storage[13];

      result.storage[12] = min(maxTx, tx).toDouble();
      result.storage[13] = min(maxTy, ty).toDouble();
      return result;
    }

    final tx = matrix.storage[12];
    final ty = matrix.storage[13];

    // Total content height in scene coordinates
    final totalPagesHeight =
        widget.controller.pages.length * AppConstants.pagePitch;
    final totalContentHeight = totalPagesHeight + 120.0;

    // Top & Bottom boundary clamping
    // Top of Page 1 stops at top cushion (max 40px down from viewport top)
    const maxTy = 40.0;
    // Bottom cushion allows scrolling comfortably past the last page
    final minTy = min(
      maxTy,
      viewportSize.height - (scale * (totalContentHeight + 350.0)),
    );
    final clampedTy = ty.clamp(minTy, maxTy).toDouble();

    // Horizontal boundary clamping (centered page +/- margin)
    final pageScreenWidth = scale * AppConstants.defaultPageSize.width;
    final centerX = (viewportSize.width - pageScreenWidth) / 2.0;
    final maxHorizontalMargin = max(200.0, 450.0 * scale);
    final minTx = centerX - maxHorizontalMargin;
    final maxTx = centerX + maxHorizontalMargin;
    final clampedTx = tx.clamp(min(minTx, maxTx), max(minTx, maxTx)).toDouble();

    final result = matrix.clone();
    if ((scale - currentScale).abs() > 0.0001) {
      final factor = scale / currentScale;
      result.storage[0] *= factor;
      result.storage[5] *= factor;
    }
    result.storage[12] = clampedTx;
    result.storage[13] = clampedTy;
    return result;
  }

  void _setTransformation(Matrix4 matrix) {
    if (_animController.isAnimating) {
      _animController.stop();
    }
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      _transformationController.value = _clampTransformation(matrix, box.size);
    } else {
      _transformationController.value = matrix;
    }
  }

  void _animateToMatrix(Matrix4 targetMatrix) {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final clampedTarget = box != null && box.hasSize
        ? _clampTransformation(targetMatrix, box.size)
        : targetMatrix;

    _animController.stop();
    _matrixAnimation = Matrix4Tween(
      begin: _transformationController.value,
      end: clampedTarget,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
    ));
    _animController.forward(from: 0.0);
  }

  void _centerCanvasInViewport() {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      final viewportWidth = box.size.width;
      final baseScale = _getBaseScale(viewportWidth);
      final initialX =
          (viewportWidth - baseScale * AppConstants.defaultPageSize.width) / 2.0;
      final targetMatrix = Matrix4.identity()
        ..translate(initialX, 24.0)
        ..scale(baseScale, baseScale, 1.0);
      _setTransformation(targetMatrix);
    }
  }

  void _scrollToPage(int pageIndex) {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    final viewportWidth = box.size.width;
    final currentScale = _getScale(_transformationController.value);

    final targetX =
        (viewportWidth - currentScale * AppConstants.defaultPageSize.width) /
            2.0;
    final pageSheetTop = pageIndex * AppConstants.pagePitch;
    final targetY = 24.0 - (currentScale * pageSheetTop);

    final targetMatrix = Matrix4.identity()
      ..translate(targetX, targetY)
      ..scale(currentScale, currentScale, 1.0);

    _animateToMatrix(targetMatrix);
  }

  RichTextEditingController _getOrCreateTextController(NoteTextBox box) {
    var ctrl = _textControllers[box.id];
    if (ctrl == null) {
      ctrl = RichTextEditingController(
        text: box.text,
        spans: box.spans,
        defaultHeading: widget.controller.activeTextHeading,
        defaultBold: widget.controller.activeTextBold,
        defaultItalic: widget.controller.activeTextItalic,
        defaultUnderline: widget.controller.activeTextUnderline,
        defaultStrikethrough: widget.controller.activeTextStrikethrough,
        defaultColor: widget.controller.activeTextColor,
        defaultHighlight: widget.controller.activeTextHighlight,
        defaultFontSize:
            box.defaultFontSize ?? widget.controller.preferredFontSize,
        headingDefaultFontSizes: box.headingDefaultFontSizes ??
            widget.controller.preferredHeadingFontSizes,
      );
      ctrl.addListener(() {
        box.text = ctrl!.text;
        box.spans = ctrl.spans;
        box.headingDefaultFontSizes = ctrl.headingDefaultFontSizes;
      });
      _textControllers[box.id] = ctrl;
    }
    return ctrl;
  }

  @override
  void dispose() {
    _animController.dispose();
    _transformationController.removeListener(_onTransformationChanged);
    for (final ctrl in _textControllers.values) {
      ctrl.dispose();
    }
    _transformationController.dispose();
    super.dispose();
  }

  void _zoomIn() {
    _applyZoom(1.2);
  }

  void _zoomOut() {
    _applyZoom(1.0 / 1.2);
  }

  void _zoomAtPoint(Offset pos, double factor) {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final viewportWidth = box != null && box.hasSize ? box.size.width : 600.0;
    final baseScale = _getBaseScale(viewportWidth);
    final minScale = AppConstants.minScale * baseScale;
    final maxScale = AppConstants.maxScale * baseScale;

    final currentScale = _getScale(_transformationController.value);
    final targetScale = (currentScale * factor).clamp(minScale, maxScale);
    if ((targetScale - currentScale).abs() < 0.0001) return;
    final effectiveFactor = targetScale / currentScale;

    final matrix = _transformationController.value.clone();
    final translationBefore =
        Matrix4.translationValues(-pos.dx, -pos.dy, 0.0);
    final scaleMatrix =
        Matrix4.diagonal3Values(effectiveFactor, effectiveFactor, 1.0);
    final translationAfter =
        Matrix4.translationValues(pos.dx, pos.dy, 0.0);

    final transform = translationAfter * scaleMatrix * translationBefore;
    _setTransformation(transform * matrix);
  }

  void _applyZoom(double factor) {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final center = box != null && box.hasSize
        ? Offset(box.size.width / 2.0, box.size.height / 2.0)
        : const Offset(400.0, 400.0);
    _zoomAtPoint(center, factor);
  }

  /// Resets zoom to 100% in-place at the current viewport center without jumping pages.
  void _resetZoomInPlace() {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final center = box != null && box.hasSize
        ? Offset(box.size.width / 2.0, box.size.height / 2.0)
        : const Offset(400.0, 400.0);
    final viewportWidth = box != null && box.hasSize ? box.size.width : 600.0;
    final baseScale = _getBaseScale(viewportWidth);
    final currentScale = _getScale(_transformationController.value);
    if ((currentScale - baseScale).abs() < 0.001) return;
    _zoomAtPoint(center, baseScale / currentScale);
  }

  /// Resets zoom to 100% and re-centers the active page in view.
  void _resetViewAndCenter() {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      final viewportWidth = box.size.width;
      final baseScale = _getBaseScale(viewportWidth);
      final initialX =
          (viewportWidth - baseScale * AppConstants.defaultPageSize.width) / 2.0;
      final activeIdx = widget.controller.activePageIndex;
      final pageSheetTop = activeIdx * AppConstants.pagePitch;
      final targetY = 24.0 - (baseScale * pageSheetTop);
      final targetMatrix = Matrix4.identity()
        ..translate(initialX, targetY)
        ..scale(baseScale, baseScale, 1.0);
      _animateToMatrix(targetMatrix);
    }
  }

  OffScreenDirection _detectOffScreenDirection(
    Matrix4 matrix,
    Size viewportSize,
  ) {
    if (viewportSize.width <= 0 || viewportSize.height <= 0) {
      return OffScreenDirection.none;
    }

    final scale = _getScale(matrix);
    final tx = matrix.storage[12];
    final ty = matrix.storage[13];

    final isInfinite = widget.controller.isInfinite;
    final activeIdx = isInfinite ? 0 : widget.controller.activePageIndex;
    final pageSheetTop = isInfinite ? 0.0 : activeIdx * AppConstants.pagePitch;
    final pageSheetHeight = isInfinite
        ? AppConstants.defaultPageSize.height
        : AppConstants.pageHeaderHeight + AppConstants.defaultPageSize.height;

    final vPageTop = ty + scale * pageSheetTop;
    final vPageBottom = ty + scale * (pageSheetTop + pageSheetHeight);
    final vPageLeft = tx;
    final vPageRight = tx + scale * AppConstants.defaultPageSize.width;

    // Active page / content origin is scrolled above viewport
    if (vPageBottom < 40.0) {
      return OffScreenDirection.above;
    }
    // Active page / content origin is scrolled below viewport
    if (vPageTop > viewportSize.height - 40.0) {
      return OffScreenDirection.below;
    }
    // Active page / content origin is scrolled off to the left
    if (vPageRight < 40.0) {
      return OffScreenDirection.left;
    }
    // Active page / content origin is scrolled off to the right
    if (vPageLeft > viewportSize.width - 40.0) {
      return OffScreenDirection.right;
    }

    return OffScreenDirection.none;
  }

  Widget _buildBackToPageIndicator(
    OffScreenDirection direction,
    int activePage,
  ) {
    if (direction == OffScreenDirection.none ||
        widget.controller.isTransforming) {
      return const SizedBox.shrink();
    }
    final isInfinite = widget.controller.isInfinite;

    final (IconData icon, Alignment alignment, EdgeInsets padding) =
        switch (direction) {
      OffScreenDirection.above => (
          Icons.arrow_upward_rounded,
          Alignment.topCenter,
          const EdgeInsets.only(top: 16.0),
        ),
      OffScreenDirection.below => (
          Icons.arrow_downward_rounded,
          Alignment.bottomCenter,
          const EdgeInsets.only(bottom: 24.0),
        ),
      OffScreenDirection.left => (
          Icons.arrow_back_rounded,
          Alignment.centerLeft,
          const EdgeInsets.only(left: 16.0),
        ),
      OffScreenDirection.right => (
          Icons.arrow_forward_rounded,
          Alignment.centerRight,
          const EdgeInsets.only(right: 16.0),
        ),
      OffScreenDirection.none => (
          Icons.circle,
          Alignment.center,
          EdgeInsets.zero,
        ),
    };

    return Align(
      alignment: alignment,
      child: Padding(
        padding: padding,
        child: Material(
          key: const Key('back_to_page_indicator'),
          elevation: 4,
          borderRadius: BorderRadius.circular(20),
          color: Colors.white,
          shadowColor: Colors.black26,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: isInfinite
                ? _resetViewAndCenter
                : () => _scrollToPage(activePage),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.35),
                  width: 1.2,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: AppColors.primary),
                  const SizedBox(width: 6),
                  Text(
                    isInfinite ? 'Back to Origin' : 'Page ${activePage + 1}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingZoomControls(double scale, double viewportWidth) {
    final baseScale = _getBaseScale(viewportWidth);
    final percent = ((scale / baseScale) * 100).round();
    final minScale = AppConstants.minScale * baseScale;
    final maxScale = AppConstants.maxScale * baseScale;
    final canZoomOut = scale > minScale + 0.01;
    final canZoomIn = scale < maxScale - 0.01;

    return Positioned(
      right: 16,
      bottom: 16,
      child: Material(
        elevation: 3,
        borderRadius: BorderRadius.circular(24),
        color: Colors.white,
        shadowColor: Colors.black26,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.grey.shade300, width: 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.remove, size: 18),
                tooltip: 'Zoom Out (Min 50%)',
                onPressed: canZoomOut ? _zoomOut : null,
              ),
              Tooltip(
                message: 'Reset Zoom (100%)',
                child: InkWell(
                  key: const Key('zoom_percentage_button'),
                  onTap: _resetZoomInPlace,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6.0,
                      vertical: 6.0,
                    ),
                    child: Text(
                      '$percent%',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: canZoomOut && canZoomIn
                            ? Colors.black87
                            : Colors.black54,
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                tooltip: 'Zoom In (Max 300%)',
                onPressed: canZoomIn ? _zoomIn : null,
              ),
              Container(
                width: 1,
                height: 18,
                color: Colors.grey.shade300,
              ),
              IconButton(
                key: const Key('reset_view_button'),
                icon: const Icon(Icons.fit_screen, size: 18),
                tooltip: 'Fit / Reset View',
                onPressed: _resetViewAndCenter,
              ),
            ],
          ),
        ),
      ),
    );
  }

  MouseCursor get _currentCursor {
    return switch (widget.controller.activeTool) {
      ToolType.pen ||
      ToolType.fountainPen ||
      ToolType.highlighter ||
      ToolType.lasso =>
        SystemMouseCursors.precise,
      ToolType.text => SystemMouseCursors.text,
      ToolType.strokeEraser || ToolType.areaEraser => SystemMouseCursors.click,
      ToolType.pan => SystemMouseCursors.grab,
    };
  }

  bool _isPointerOverAnyTextBox(Offset scenePos) {
    if (widget.controller.activeTool != ToolType.text) return false;
    final isInfinite = widget.controller.isInfinite;
    for (int i = 0; i < widget.controller.pages.length; i++) {
      final page = widget.controller.pages[i];
      final pageOriginY = isInfinite
          ? 0.0
          : AppConstants.pageHeaderHeight + i * AppConstants.pagePitch;
      for (final box in page.textBoxes) {
        final boxRect = Rect.fromLTWH(
          box.position.dx,
          pageOriginY + box.position.dy,
          box.width,
          box.height ?? 48.0,
        ).inflate(28.0);
        if (boxRect.contains(scenePos)) {
          return true;
        }
      }
    }
    return false;
  }

  bool _isPointerOverAnyImage(Offset scenePos) {
    final canInteract = widget.controller.activeTool == ToolType.text ||
        widget.controller.activeTool == ToolType.lasso ||
        widget.controller.selectedImageId != null;
    if (!canInteract) return false;

    final isInfinite = widget.controller.isInfinite;
    for (int i = 0; i < widget.controller.pages.length; i++) {
      final page = widget.controller.pages[i];
      final pageOriginY = isInfinite
          ? 0.0
          : AppConstants.pageHeaderHeight + i * AppConstants.pagePitch;
      for (final img in page.images) {
        final isSelected = widget.controller.selectedImageId == img.id;
        final bottomExtra = isSelected ? 72.0 : 16.0;
        final topExtra = isSelected ? 32.0 : 16.0;
        final horizontalExtra = isSelected ? 72.0 : 16.0;
        final imgRect = Rect.fromLTRB(
          img.position.dx - horizontalExtra,
          pageOriginY + img.position.dy - topExtra,
          img.position.dx + img.width + horizontalExtra,
          pageOriginY + img.position.dy + img.height + bottomExtra,
        );
        if (imgRect.contains(scenePos)) {
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _handlePaste() async {
    final hasPasted = await widget.controller.pasteImageFromClipboard();
    if (hasPasted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Image pasted onto canvas'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        DrawingToolbar(controller: widget.controller),
        Expanded(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.keyV, control: true): _handlePaste,
              const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _handlePaste,
            },
            child: Focus(
              autofocus: true,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final viewportSize = constraints.biggest;
                  return ListenableBuilder(
                    listenable: widget.controller,
                    builder: (context, _) {
                      final isPanTool = widget.controller.activeTool == ToolType.pan;

                      final isDark = widget.controller.isDarkMode;

                      return MouseRegion(
                        cursor: _currentCursor,
                        child: Container(
                          color: isDark
                              ? AppColors.pasteboardBackgroundDark
                              : AppColors.pasteboardBackground,
                          child: Stack(
                      children: [
                        // Full-viewport gesture listener with matrix inversion (never clips or dead-zones)
                        Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerSignal: (pointerSignal) {
                          if (pointerSignal is PointerScaleEvent) {
                            // Web & Trackpad pinch-to-zoom / Ctrl+Wheel signal from browser
                            _zoomAtPoint(pointerSignal.localPosition, pointerSignal.scale);
                          } else if (pointerSignal is PointerScrollEvent) {
                            final isCtrlPressed =
                                HardwareKeyboard.instance.isControlPressed ||
                                    HardwareKeyboard.instance.isMetaPressed;

                            if (isCtrlPressed) {
                              // Ctrl + Scrollwheel: Zoom in or out centered at cursor position
                              final dy = pointerSignal.scrollDelta.dy;
                              if (dy == 0.0) return;

                              // Smooth exponential zoom factor (dy < 0 zooms in, dy > 0 zooms out)
                              final zoomFactor = exp(-dy * 0.002);
                              _zoomAtPoint(pointerSignal.localPosition, zoomFactor);
                            } else {
                              // Scrollwheel ONLY: Smoothly scroll / pan the canvas without zooming
                              final matrix = _transformationController.value.clone();
                              matrix.leftTranslate(
                                -pointerSignal.scrollDelta.dx,
                                -pointerSignal.scrollDelta.dy,
                              );
                              _setTransformation(matrix);
                            }
                          }
                        },
                    onPointerDown: (e) {
                      // Stylus palm rejection: ignore touch pointer if stylus is currently drawing
                      if (_primaryDrawingPointer != null &&
                          _primaryPointerKind == PointerDeviceKind.stylus &&
                          e.kind == PointerDeviceKind.touch) {
                        return;
                      }

                      _activePointers[e.pointer] = e.localPosition;

                      if (_activePointers.length >= 2) {
                        // Dismiss soft keyboard and unfocus active text box when multi-touch pinch starts
                        FocusManager.instance.primaryFocus?.unfocus();
                        widget.controller.unfocusActiveTextBox();

                        // Multi-touch pinch / pan initiated: cancel any pending single-finger stroke or text tap
                        final primaryPtr = _primaryDrawingPointer;
                        if (primaryPtr != null) {
                          widget.controller.onPointerCancel(pointer: primaryPtr);
                          _primaryDrawingPointer = null;
                        }
                        _isPinching = true;
                        final pts = _activePointers.values.toList();
                        _initialPinchDistance = (pts[0] - pts[1]).distance;
                        _initialPinchFocal = (pts[0] + pts[1]) / 2.0;
                        _initialPinchMatrix = _transformationController.value.clone();
                        return;
                      }

                      if (_isPinching) return;

                      _primaryDrawingPointer = e.pointer;
                      _primaryPointerKind = e.kind;

                      if (widget.controller.activeTool == ToolType.pan) return;

                      final scenePos =
                          _transformationController.toScene(e.localPosition);
                      final isInfinite = widget.controller.isInfinite;
                      final boardX = scenePos.dx;
                      final boardY = scenePos.dy;
                      final touchPageIndex = isInfinite
                          ? 0
                          : (boardY / AppConstants.pagePitch)
                              .floor()
                              .clamp(0, widget.controller.pages.length - 1);
                      final totalPagesHeight =
                          widget.controller.pages.length * AppConstants.pagePitch;
                      final pageTopY = touchPageIndex * AppConstants.pagePitch;

                      // Priority 1: Check active selection handles, rotation stem, and toolbar
                      bool isInteractingWithSelection = false;
                      if (widget.controller.hasSelection &&
                          widget.controller.selectionBounds != null) {
                        final activeIdx = isInfinite ? 0 : widget.controller.activePageIndex;
                        final canvasOrigin = isInfinite
                            ? Offset.zero
                            : Offset(
                                0.0,
                                AppConstants.pageHeaderHeight +
                                    activeIdx * AppConstants.pagePitch,
                              );
                        final globalBounds = widget.controller
                            .selectionBounds!
                            .shift(canvasOrigin);

                        Offset effectivePos = scenePos;
                        if (widget.controller.selectionRotation != 0.0) {
                          effectivePos = LassoService.unrotatePoint(
                            scenePos,
                            globalBounds.center,
                            widget.controller.selectionRotation,
                          );
                        }
                        final handle = LassoService.hitTestHandle(
                          effectivePos,
                          globalBounds,
                        );
                        final toolbarRect = SelectionToolbar.getToolbarRect(
                          globalBounds,
                          rotationAngle:
                              widget.controller.selectionRotation,
                        );
                        if (handle != LassoHandle.none ||
                            toolbarRect.contains(scenePos)) {
                          isInteractingWithSelection = true;
                        }
                      }

                      // Priority 2: Filter non-lasso interactions over UI buttons/headers
                      if (!isInteractingWithSelection && !isInfinite) {
                        final isOverAddButton = boardX >= 0 &&
                            boardX <= AppConstants.defaultPageSize.width &&
                            boardY >= totalPagesHeight &&
                            boardY <= totalPagesHeight + 52.0;

                        final isOverHeader = boardX >= 0 &&
                            boardX <= AppConstants.defaultPageSize.width &&
                            boardY >= pageTopY &&
                            boardY < pageTopY + AppConstants.pageHeaderHeight;

                        if ((isOverAddButton || isOverHeader) &&
                            widget.controller.activeTool != ToolType.lasso) {
                          return;
                        }

                        // Switch active page only if not using the lasso tool
                        // (lasso selection detects the correct page upon pointer up)
                        if (widget.controller.activeTool != ToolType.lasso &&
                            widget.controller.activePageIndex != touchPageIndex) {
                          widget.controller.setActivePage(touchPageIndex);
                        }
                      }

                      final activeIdx = isInfinite ? 0 : widget.controller.activePageIndex;
                      final localX = boardX;
                      final localY = isInfinite
                          ? boardY
                          : boardY -
                              (AppConstants.pageHeaderHeight +
                                  activeIdx * AppConstants.pagePitch);

                      // If touching inside an existing text box or image,
                      // let the widget's own gesture detectors handle drag, resize, and interaction
                      if (!isInteractingWithSelection &&
                          (_isPointerOverAnyTextBox(scenePos) ||
                              _isPointerOverAnyImage(scenePos))) {
                        _primaryDrawingPointer = null;
                        return;
                      }

                      widget.controller.onPointerDown(
                        Offset(localX, localY),
                        pointer: e.pointer,
                        kind: e.kind,
                        pressure: e.pressure,
                        buttons: e.buttons,
                      );
                    },
                    onPointerMove: (e) {
                      if (!_activePointers.containsKey(e.pointer)) return;
                      _activePointers[e.pointer] = e.localPosition;

                      if (_isPinching && _activePointers.length >= 2) {
                        final pts = _activePointers.values.toList();
                        final currentDistance = (pts[0] - pts[1]).distance;
                        final currentFocal = (pts[0] + pts[1]) / 2.0;

                        if (_initialPinchDistance > 10.0) {
                          final scaleDelta = currentDistance / _initialPinchDistance;

                          final translationBefore = Matrix4.translationValues(
                            -_initialPinchFocal.dx,
                            -_initialPinchFocal.dy,
                            0.0,
                          );
                          final scaleMatrix = Matrix4.diagonal3Values(
                            scaleDelta,
                            scaleDelta,
                            1.0,
                          );
                          final translationAfter = Matrix4.translationValues(
                            currentFocal.dx,
                            currentFocal.dy,
                            0.0,
                          );

                          final transform =
                              translationAfter * scaleMatrix * translationBefore;
                          _setTransformation(transform * _initialPinchMatrix);
                        }
                        return;
                      }

                      if (_isPinching || _primaryDrawingPointer != e.pointer) {
                        return;
                      }

                      if (widget.controller.activeTool == ToolType.pan) return;

                      final scenePos =
                          _transformationController.toScene(e.localPosition);
                      final isInfinite = widget.controller.isInfinite;
                      final activeIdx = isInfinite ? 0 : widget.controller.activePageIndex;
                      final localX = scenePos.dx;
                      final localY = isInfinite
                          ? scenePos.dy
                          : scenePos.dy -
                              (AppConstants.pageHeaderHeight +
                                  activeIdx * AppConstants.pagePitch);

                      widget.controller.onPointerMove(
                        Offset(localX, localY),
                        pointer: e.pointer,
                        kind: e.kind,
                        pressure: e.pressure,
                        buttons: e.buttons,
                      );
                    },
                    onPointerUp: (e) {
                      _activePointers.remove(e.pointer);

                      if (_isPinching) {
                        if (_activePointers.isEmpty) {
                          _isPinching = false;
                        }
                        return;
                      }

                      if (_primaryDrawingPointer == e.pointer) {
                        _primaryDrawingPointer = null;

                        if (widget.controller.activeTool == ToolType.pan) return;

                        final scenePos =
                            _transformationController.toScene(e.localPosition);
                        final isInfinite = widget.controller.isInfinite;
                        final activeIdx = isInfinite ? 0 : widget.controller.activePageIndex;
                        final localX = scenePos.dx;
                        final localY = isInfinite
                            ? scenePos.dy
                            : scenePos.dy -
                                (AppConstants.pageHeaderHeight +
                                    activeIdx * AppConstants.pagePitch);

                        widget.controller.onPointerUp(
                          Offset(localX, localY),
                          pointer: e.pointer,
                          kind: e.kind,
                          pressure: e.pressure,
                          buttons: e.buttons,
                        );
                      }
                    },
                    onPointerCancel: (e) {
                      _activePointers.remove(e.pointer);

                      if (_isPinching) {
                        if (_activePointers.isEmpty) {
                          _isPinching = false;
                        }
                      }

                      if (_primaryDrawingPointer == e.pointer) {
                        _primaryDrawingPointer = null;
                        widget.controller.onPointerCancel(pointer: e.pointer);
                      }
                    },
                    child: InteractiveViewer(
                      transformationController: _transformationController,
                      boundaryMargin: widget.controller.isInfinite
                          ? EdgeInsets.only(
                              top: 40.0,
                              left: max(
                                40.0,
                                (viewportSize.width -
                                        AppConstants.defaultPageSize.width) /
                                    2.0,
                              ),
                              right: 1000000.0,
                              bottom: 1000000.0,
                            )
                          : const EdgeInsets.all(4000),
                      minScale: AppConstants.minScale,
                      maxScale: AppConstants.maxScale,
                      panEnabled: isPanTool,
                      scaleEnabled: false,
                      constrained: false,
                      onInteractionEnd: (_) {
                        final box = context.findRenderObject() as RenderBox?;
                        if (box != null && box.hasSize) {
                          _transformationController.value =
                              _clampTransformation(
                            _transformationController.value,
                            box.size,
                          );
                        }
                      },
                      child: UnboundedHitTest(
                        child: UnboundedHitTestStack(
                          clipBehavior: Clip.none,
                          children: [
                            // Layer 1: Multi-page vertical sheets OR Infinite Canvas
                            if (!widget.controller.isInfinite)
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (int i = 0;
                                      i < widget.controller.pages.length;
                                      i++) ...[
                                    _buildPageSheet(i),
                                    const SizedBox(
                                      height: AppConstants.pageGap,
                                    ),
                                  ],
                                  _buildAddPageButton(),
                                  const SizedBox(height: 48.0),
                                ],
                              )
                            else
                              _buildInfiniteCanvas(viewportSize),

                            // Layer 2: All text boxes across all pages
                            for (int i = 0;
                                i < widget.controller.pages.length;
                                i++)
                              for (final box in widget
                                  .controller.pages[i].textBoxes)
                                TextBoxWidget(
                                  key: ValueKey(box.id),
                                  textBox: box,
                                  controller: widget.controller,
                                  isSelected: widget.controller
                                          .activeTextBoxId ==
                                      box.id,
                                  richController:
                                      _getOrCreateTextController(box),
                                  boardPosition: widget.controller.isInfinite
                                      ? box.position
                                      : Offset(
                                          box.position.dx,
                                          AppConstants.pageHeaderHeight +
                                              i * AppConstants.pagePitch +
                                              box.position.dy,
                                        ),
                                ),

                            // Layer 2.5: All interactive images across all pages
                            for (int i = 0;
                                i < widget.controller.pages.length;
                                i++)
                              for (final img in widget
                                  .controller.pages[i].images)
                                NoteImageWidget(
                                  key: ValueKey(img.id),
                                  image: img,
                                  controller: widget.controller,
                                  isSelected: widget.controller
                                          .selectedImageId ==
                                      img.id,
                                  pageIndex: i,
                                  boardPosition: widget.controller.isInfinite
                                      ? img.position
                                      : Offset(
                                          img.position.dx,
                                          AppConstants.pageHeaderHeight +
                                              i * AppConstants.pagePitch +
                                              img.position.dy,
                                        ),
                                  renderRaster: false,
                                ),

                            // Layer 3: Selection bounding box, handles, toolbar, and dragged strokes
                            if (widget.controller.hasSelection &&
                                widget.controller.selectionBounds != null)
                              _buildGlobalSelectionOverlay(),

                            // Layer 4: Global Lasso in-progress freeform loop
                            ValueListenableBuilder<List<Offset>>(
                              valueListenable:
                                  widget.controller.lassoPointsNotifier,
                              builder: (context, lassoPoints, _) {
                                if (lassoPoints.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                final isInfinite = widget.controller.isInfinite;
                                final activePageIdx = isInfinite ? 0 : widget.controller.activePageIndex;
                                final canvasOrigin = isInfinite
                                    ? Offset.zero
                                    : Offset(
                                        0.0,
                                        AppConstants.pageHeaderHeight +
                                            activePageIdx *
                                                AppConstants.pagePitch,
                                      );
                                return Transform.translate(
                                  offset: canvasOrigin,
                                  child: CustomPaint(
                                    painter: LassoPathPainter(lassoPoints),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Floating Overlays: Off-screen active page indicator & live zoom controls
                  Positioned.fill(
                    child: ValueListenableBuilder<Matrix4>(
                      valueListenable: _transformationController,
                      builder: (context, matrix, _) {
                        final direction =
                            _detectOffScreenDirection(matrix, viewportSize);
                        final scale = _getScale(matrix);

                        return Stack(
                          children: [
                            _buildBackToPageIndicator(
                              direction,
                              widget.controller.activePageIndex,
                            ),
                            _buildFloatingZoomControls(scale, viewportSize.width),
                            if (widget.controller.hasSelection &&
                                widget.controller.selectionBounds != null &&
                                !widget.controller.isTransforming)
                              _buildFloatingSelectionToolbar(matrix, viewportSize),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInfiniteCanvas(Size viewportSize) {
    final page = widget.controller.pages.first;
    final isDark = widget.controller.isDarkMode;

    final renderedStrokes = widget.controller.isTransforming
        ? page.strokes
            .where((s) => !widget.controller.selectedStrokes.contains(s))
            .toList()
        : page.strokes;

    return SizedBox(
      width: AppConstants.defaultPageSize.width,
      height: AppConstants.defaultPageSize.height,
      child: UnboundedHitTest(
        child: UnboundedHitTestStack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            // 1. Seamless infinite paper background (ruled / grid lines)
            ValueListenableBuilder<Matrix4>(
              valueListenable: _transformationController,
              builder: (context, matrix, _) {
                final inverseMatrix = Matrix4.tryInvert(matrix);
                final visibleTopLeft = inverseMatrix != null
                    ? MatrixUtils.transformPoint(inverseMatrix, Offset.zero)
                    : Offset.zero;
                final visibleBottomRight = inverseMatrix != null
                    ? MatrixUtils.transformPoint(
                        inverseMatrix,
                        Offset(viewportSize.width, viewportSize.height),
                      )
                    : Offset(viewportSize.width, viewportSize.height);
                final visibleBounds =
                    Rect.fromPoints(visibleTopLeft, visibleBottomRight);

                return IgnorePointer(
                  child: CustomPaint(
                    painter: InfiniteBackgroundPainter(
                      template: widget.template,
                      isDarkMode: isDark,
                      visibleBounds: visibleBounds,
                    ),
                  ),
                );
              },
            ),

            // 2. Images on page 0
            for (final img in page.images)
              Positioned(
                key: ValueKey('page_raster_${img.id}'),
                left: img.position.dx,
                top: img.position.dy,
                width: img.width,
                height: img.height,
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: Image.memory(
                      img.bytes,
                      fit: BoxFit.fill,
                      width: img.width,
                      height: img.height,
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          color: Colors.grey.shade200,
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.broken_image_outlined,
                            color: Colors.grey,
                            size: 32,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),

            // 3. Completed Highlighters
            IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: CompletedStrokesPainter(
                    renderedStrokes,
                    layer: StrokeLayer.highlightersOnly,
                    isDarkMode: isDark,
                  ),
                ),
              ),
            ),

            // 4. Active Highlighter
            IgnorePointer(
              child: ValueListenableBuilder<List<StrokePoint>>(
                valueListenable: widget.controller.currentStrokeNotifier,
                builder: (context, currentPoints, _) {
                  if (widget.controller.activeTool != ToolType.highlighter ||
                      currentPoints.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return RepaintBoundary(
                    child: CustomPaint(
                      painter: ActiveStrokePainter(
                        points: currentPoints,
                        color: widget.controller.activeColor,
                        strokeWidth: widget.controller.strokeWidth,
                        toolType: widget.controller.activeTool,
                        isDarkMode: isDark,
                      ),
                    ),
                  );
                },
              ),
            ),

            // 5. Completed Pens & Fountain Pens
            IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: CompletedStrokesPainter(
                    renderedStrokes,
                    layer: StrokeLayer.pensOnly,
                    isDarkMode: isDark,
                  ),
                ),
              ),
            ),

            // 6. Active Pen / Fountain Pen
            IgnorePointer(
              child: ValueListenableBuilder<List<StrokePoint>>(
                valueListenable: widget.controller.currentStrokeNotifier,
                builder: (context, currentPoints, _) {
                  if (widget.controller.activeTool == ToolType.highlighter ||
                      currentPoints.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return RepaintBoundary(
                    child: CustomPaint(
                      painter: ActiveStrokePainter(
                        points: currentPoints,
                        color: widget.controller.activeColor,
                        strokeWidth: widget.controller.strokeWidth,
                        toolType: widget.controller.activeTool,
                        isDarkMode: isDark,
                      ),
                    ),
                  );
                },
              ),
            ),

            // 7. Eraser Visual Cursor
            ValueListenableBuilder<Offset?>(
              valueListenable: widget.controller.eraserPointerNotifier,
              builder: (context, eraserPos, _) {
                if (eraserPos == null) {
                  return const SizedBox.shrink();
                }
                return CustomPaint(
                  painter: EraserCursorPainter(
                    position: eraserPos,
                    radius: widget.controller.eraserRadius,
                    isAreaEraser:
                        widget.controller.activeTool == ToolType.areaEraser,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddPageButton() {
    final isDark = widget.controller.isDarkMode;
    return SizedBox(
      width: AppConstants.defaultPageSize.width,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: isDark ? Colors.white : AppColors.primary,
          side: BorderSide(
            color: isDark
                ? Colors.white24
                : AppColors.primary.withValues(alpha: 0.6),
            width: 1.5,
          ),
          padding: const EdgeInsets.symmetric(vertical: 14.0),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8.0),
          ),
          backgroundColor: isDark ? const Color(0xFF22222A) : Colors.white,
          elevation: 1,
        ),
        icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
        label: const Text(
          'Add New Page',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        onPressed: () {
          widget.controller.addPage();
        },
      ),
    );
  }

  Widget _buildPageSheet(int pageIndex) {
    final page = widget.controller.pages[pageIndex];
    final isActivePage = widget.controller.activePageIndex == pageIndex;
    final isDark = widget.controller.isDarkMode;

    final renderedStrokes = isActivePage && widget.controller.isTransforming
        ? page.strokes
            .where((s) => !widget.controller.selectedStrokes.contains(s))
            .toList()
        : page.strokes;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Page Header Indicator
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0, left: 4.0, right: 4.0),
          child: SizedBox(
            width: AppConstants.defaultPageSize.width,
            height: 24.0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: isActivePage
                        ? AppColors.primary
                        : Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Page ${pageIndex + 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (widget.controller.pages.length > 1)
                  Tooltip(
                    message: 'Delete Page ${pageIndex + 1}',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => widget.controller.deletePage(pageIndex),
                      child: Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                          color: isDark
                              ? Colors.grey.shade400
                              : Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),

        // Page Canvas Container (unclipped so margin notes and drags are visible)
        Container(
          width: AppConstants.defaultPageSize.width,
          height: AppConstants.defaultPageSize.height,
          decoration: BoxDecoration(
            color: isDark
                ? AppColors.canvasBackgroundDark
                : AppColors.canvasBackground,
            borderRadius: BorderRadius.circular(2.0),
            border: Border.all(
              color: isActivePage
                  ? AppColors.primary.withValues(alpha: isDark ? 0.85 : 0.6)
                  : (isDark
                      ? AppColors.canvasBorderDark
                      : AppColors.canvasBorder),
              width: isActivePage ? 1.5 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: isActivePage
                    ? AppColors.primary.withValues(alpha: isDark ? 0.25 : 0.12)
                    : (isDark
                        ? AppColors.canvasShadowDark
                        : AppColors.canvasShadow),
                blurRadius: 10.0,
                spreadRadius: 2.0,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: UnboundedHitTest(
            child: UnboundedHitTestStack(
              clipBehavior: Clip.none,
              fit: StackFit.expand,
              children: [
                // 1. Page Background (plain, lined, or grid)
                IgnorePointer(
                  child: CustomPaint(
                    painter: PageBackgroundPainter(
                      template: widget.template,
                      isDarkMode: isDark,
                    ),
                  ),
                ),

                // 2. Images on this page (raster layer beneath highlighters and pens for clean annotation)
                for (final img in page.images)
                  Positioned(
                    key: ValueKey('page_raster_${img.id}'),
                    left: img.position.dx,
                    top: img.position.dy,
                    width: img.width,
                    height: img.height,
                    child: IgnorePointer(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Image.memory(
                          img.bytes,
                          fit: BoxFit.fill,
                          width: img.width,
                          height: img.height,
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              color: Colors.grey.shade200,
                              alignment: Alignment.center,
                              child: const Icon(
                                Icons.broken_image_outlined,
                                color: Colors.grey,
                                size: 32,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),

                // 3. Completed Highlighters
                IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: CompletedStrokesPainter(
                        renderedStrokes,
                        layer: StrokeLayer.highlightersOnly,
                        isDarkMode: isDark,
                      ),
                    ),
                  ),
                ),

                // 4. Active Highlighter (on active page)
                if (isActivePage)
                  IgnorePointer(
                    child: ValueListenableBuilder<List<StrokePoint>>(
                      valueListenable: widget.controller.currentStrokeNotifier,
                      builder: (context, currentPoints, _) {
                        if (widget.controller.activeTool !=
                                ToolType.highlighter ||
                            currentPoints.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        return RepaintBoundary(
                          child: CustomPaint(
                            painter: ActiveStrokePainter(
                              points: currentPoints,
                              color: widget.controller.activeColor,
                              strokeWidth: widget.controller.strokeWidth,
                              toolType: widget.controller.activeTool,
                              isDarkMode: isDark,
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                // 5. Completed Pens & Fountain Pens
                IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: CompletedStrokesPainter(
                        renderedStrokes,
                        layer: StrokeLayer.pensOnly,
                        isDarkMode: isDark,
                      ),
                    ),
                  ),
                ),

                // 6. Active Pen / Fountain Pen (on active page)
                if (isActivePage)
                  IgnorePointer(
                    child: ValueListenableBuilder<List<StrokePoint>>(
                      valueListenable: widget.controller.currentStrokeNotifier,
                      builder: (context, currentPoints, _) {
                        if (widget.controller.activeTool ==
                                ToolType.highlighter ||
                            currentPoints.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        return RepaintBoundary(
                          child: CustomPaint(
                            painter: ActiveStrokePainter(
                              points: currentPoints,
                              color: widget.controller.activeColor,
                              strokeWidth: widget.controller.strokeWidth,
                              toolType: widget.controller.activeTool,
                              isDarkMode: isDark,
                            ),
                          ),
                        );
                      },
                    ),
                  ),

              // 6. Eraser Visual Cursor (on active page)
              if (isActivePage)
                ValueListenableBuilder<Offset?>(
                  valueListenable: widget.controller.eraserPointerNotifier,
                  builder: (context, eraserPos, _) {
                    if (eraserPos == null) {
                      return const SizedBox.shrink();
                    }
                    return CustomPaint(
                      painter: EraserCursorPainter(
                        position: eraserPos,
                        radius: widget.controller.eraserRadius,
                        isAreaEraser: widget.controller.activeTool ==
                            ToolType.areaEraser,
                      ),
                    );
                  },
                ),

              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Global selection overlay rendered across the entire multi-page Column so dragged strokes,
  /// selection bounding boxes, and handles can cross page boundaries and margins without clipping.
  Widget _buildGlobalSelectionOverlay() {
    final isInfinite = widget.controller.isInfinite;
    final activePageIdx = isInfinite ? 0 : widget.controller.activePageIndex;
    final canvasOrigin = isInfinite
        ? Offset.zero
        : Offset(
            0.0,
            AppConstants.pageHeaderHeight +
                activePageIdx * AppConstants.pagePitch,
          );
    final globalBounds = widget.controller.selectionBounds!.shift(canvasOrigin);

    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 1. Dragged strokes floating above all pages and margins while transforming
          if (widget.controller.isTransforming)
            Transform.translate(
              offset: canvasOrigin,
              child: CustomPaint(
                painter: CompletedStrokesPainter(
                  widget.controller.selectedStrokes,
                  isDarkMode: widget.controller.isDarkMode,
                ),
              ),
            ),

          // 2. Selection dashed bounding box, corner handles, and rotation stem
          IgnorePointer(
            ignoring: true,
            child: CustomPaint(
              painter: SelectionPainter(
                bounds: globalBounds,
                rotationAngle: widget.controller.selectionRotation,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Floating selection contextual toolbar rendered in viewport coordinates so that
  /// it is always 100% clickable anywhere on screen (both on-page and in the pasteboard)
  /// and maintains standard touch-target sizing without page boundary clipping.
  Widget _buildFloatingSelectionToolbar(Matrix4 matrix, Size viewportSize) {
    final isInfinite = widget.controller.isInfinite;
    final activePageIdx = isInfinite ? 0 : widget.controller.activePageIndex;
    final canvasOrigin = isInfinite
        ? Offset.zero
        : Offset(
            0.0,
            AppConstants.pageHeaderHeight +
                activePageIdx * AppConstants.pagePitch,
          );
    final globalBounds = widget.controller.selectionBounds!.shift(canvasOrigin);
    final sceneToolbarRect = SelectionToolbar.getToolbarRect(
      globalBounds,
      rotationAngle: widget.controller.selectionRotation,
    );

    final screenTopLeft =
        MatrixUtils.transformPoint(matrix, sceneToolbarRect.topLeft);
    final clampedX = screenTopLeft.dx
        .clamp(8.0, max(8.0, viewportSize.width - 200.0))
        .toDouble();
    final clampedY = screenTopLeft.dy
        .clamp(8.0, max(8.0, viewportSize.height - 56.0))
        .toDouble();

    return SelectionToolbar(
      controller: widget.controller,
      bounds: globalBounds,
      rotationAngle: widget.controller.selectionRotation,
      screenPosition: Offset(clampedX, clampedY),
    );
  }
}
