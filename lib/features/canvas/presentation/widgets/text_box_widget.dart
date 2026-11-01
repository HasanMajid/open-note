import 'dart:math';
import 'package:flutter/material.dart';
import 'package:open_note/core/theme/app_colors.dart';
import 'package:open_note/features/canvas/controllers/canvas_controller.dart';
import 'package:open_note/features/canvas/controllers/rich_text_editing_controller.dart';
import 'package:open_note/features/canvas/models/note_text_box.dart';
import 'package:open_note/features/canvas/models/tool_type.dart';
import 'package:open_note/features/canvas/presentation/widgets/unbounded_hit_test.dart';

/// An interactive, movable, and resizable rich text box placed directly on the canvas page.
class TextBoxWidget extends StatefulWidget {
  final NoteTextBox textBox;
  final CanvasController controller;
  final bool isSelected;
  final RichTextEditingController richController;
  final Offset? boardPosition;

  const TextBoxWidget({
    super.key,
    required this.textBox,
    required this.controller,
    required this.isSelected,
    required this.richController,
    this.boardPosition,
  });

  @override
  State<TextBoxWidget> createState() => _TextBoxWidgetState();
}

class _TextBoxWidgetState extends State<TextBoxWidget> {
  late final FocusNode _focusNode;
  bool _isDragging = false;
  Offset? _dragStartPos;
  double? _dragInitialX;
  double? _dragInitialY;

  bool _isResizing = false;
  double? _resizeStartX;
  double? _resizeInitialWidth;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);

    if (widget.isSelected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.controller.setActiveRichTextController(widget.richController);
          if (!_focusNode.hasFocus) {
            _focusNode.requestFocus();
          }
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant TextBoxWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final isTextTool = widget.controller.activeTool == ToolType.text;
    if (!isTextTool && _focusNode.hasFocus) {
      _focusNode.unfocus();
    }
    if (isTextTool && widget.isSelected && !oldWidget.isSelected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.controller.setActiveRichTextController(widget.richController);
          if (!_focusNode.hasFocus) {
            _focusNode.requestFocus();
          }
        }
      });
    } else if ((!widget.isSelected || !isTextTool) && oldWidget.isSelected) {
      if (_focusNode.hasFocus) {
        _focusNode.unfocus();
      }
    }
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      if (widget.controller.activeTool == ToolType.text) {
        widget.controller.selectTextBox(widget.textBox.id);
        widget.controller.setActiveRichTextController(widget.richController);
      } else {
        _focusNode.unfocus();
      }
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isTextTool = widget.controller.activeTool == ToolType.text;
    final isSelected = widget.isSelected && isTextTool;
    final box = widget.textBox;

    final renderLeft = widget.boardPosition?.dx ?? box.position.dx;
    final renderTop = widget.boardPosition?.dy ?? box.position.dy;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderBox = context.findRenderObject() as RenderBox?;
      if (renderBox != null && renderBox.hasSize) {
        final actualHeight = renderBox.size.height;
        if (widget.textBox.height != actualHeight) {
          widget.textBox.height = actualHeight;
        }
      }
    });

    final effectiveDirection = widget.textBox.textDirection ??
        (NoteTextBox.isRtlText(widget.richController.text)
            ? TextDirection.rtl
            : TextDirection.ltr);
    final isRtl = effectiveDirection == TextDirection.rtl;

    return Positioned(
      left: renderLeft,
      top: renderTop,
      width: box.width,
      child: UnboundedHitTest(
        child: UnboundedHitTestStack(
          clipBehavior: Clip.none,
          children: [
            // 1. Text Content Container (Fixed anchor: Never jumps or changes width on focus)
            IgnorePointer(
              ignoring: !isTextTool,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isSelected ? const Color(0xFF007AFF) : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10.0,
                  vertical: 6.0,
                ),
                child: Material(
                  color: Colors.transparent,
                  child: ListenableBuilder(
                    listenable: widget.richController,
                    builder: (context, _) {
                      final isDark = widget.controller.isDarkMode;
                      widget.richController.isDarkMode = isDark;
                      final activeSize = widget.richController.activeFontSize;
                      return TextField(
                        controller: widget.richController,
                        focusNode: _focusNode,
                        readOnly: !isTextTool,
                        canRequestFocus: isTextTool,
                        autofocus: isSelected,
                        maxLines: null,
                        textDirection: effectiveDirection,
                        textAlign: isRtl ? TextAlign.right : TextAlign.left,
                        keyboardType: TextInputType.multiline,
                        cursorColor: isDark ? Colors.white : AppColors.primary,
                        cursorHeight: activeSize * 1.25,
                        strutStyle: StrutStyle(
                          fontSize: activeSize,
                          height: 1.4,
                          forceStrutHeight: false,
                        ),
                        style: TextStyle(
                          fontSize: activeSize,
                          color: isDark ? Colors.white : Colors.black87,
                          decorationColor: isDark ? Colors.white : Colors.black87,
                          height: 1.4,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          border: InputBorder.none,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),

            // 2. Top Drag Handle (Floats above text at top: -22, never pushing content down)
            if (isSelected)
              Positioned(
                top: -22,
                left: 0,
                right: 0,
                height: 20,
                child: _buildDragHandle(),
              ),

            // 3. Right-edge Resize Handle (Floats at right edge: -12, never shrinking content width)
            if (isSelected)
              Positioned(
                top: 0,
                bottom: 0,
                right: -12,
                width: 24,
                child: _buildResizeHandle(isLeft: false),
              ),

            // 4. Left-edge Resize Handle (Floats at left edge: -12, allows intuitive resizing for RTL/LTR)
            if (isSelected)
              Positioned(
                top: 0,
                bottom: 0,
                left: -12,
                width: 24,
                child: _buildResizeHandle(isLeft: true),
              ),
          ],
        ),
      ),
    );
  }

  /// Top pill handle to drag and move the text container on the canvas
  Widget _buildDragHandle() {
    return Center(
      child: MouseRegion(
        key: const Key('text_box_drag_handle'),
        cursor: SystemMouseCursors.move,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) {
            widget.controller.beginTextBoxTransform();
            setState(() => _isDragging = true);
            _dragStartPos = details.globalPosition;
            _dragInitialX = widget.textBox.position.dx;
            _dragInitialY = widget.textBox.position.dy;
          },
          onPanUpdate: (details) {
            if (!_isDragging || _dragStartPos == null) return;
            final scale = widget.controller.canvasScale;
            final delta = (details.globalPosition - _dragStartPos!) / scale;
            final newX = _dragInitialX! + delta.dx;
            final newY = _dragInitialY! + delta.dy;
            widget.controller.updateTextBoxPosition(
              widget.textBox.id,
              Offset(newX, newY),
            );
          },
          onPanEnd: (_) {
            setState(() => _isDragging = false);
            _dragStartPos = null;
            widget.controller.transferTextBoxIfNeeded(widget.textBox.id);
            widget.controller.commitTextBoxTransform();
          },
          child: Container(
            width: 48,
            height: 18,
            decoration: BoxDecoration(
              color: const Color(0xFF007AFF).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: const Color(0xFF007AFF).withValues(alpha: 0.4),
                width: 1.0,
              ),
            ),
            child: Center(
              child: Container(
                width: 26,
                height: 3.5,
                decoration: BoxDecoration(
                  color: const Color(0xFF007AFF),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Full-height handle to widen or narrow the text container reliably from left or right edge
  Widget _buildResizeHandle({required bool isLeft}) {
    return MouseRegion(
      key: Key(isLeft ? 'text_box_resize_handle_left' : 'text_box_resize_handle'),
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) {
          widget.controller.beginTextBoxTransform();
          setState(() => _isResizing = true);
          _resizeStartX = details.globalPosition.dx;
          _resizeInitialWidth = widget.textBox.width;
          _dragInitialX = widget.textBox.position.dx;
        },
        onPanUpdate: (details) {
          if (!_isResizing || _resizeStartX == null) return;
          final scale = widget.controller.canvasScale;
          final deltaX = (details.globalPosition.dx - _resizeStartX!) / scale;
          if (isLeft) {
            final newWidth = max(
              NoteTextBox.minWidth,
              _resizeInitialWidth! - deltaX,
            );
            final actualDeltaX = _resizeInitialWidth! - newWidth;
            widget.textBox.width = newWidth;
            widget.textBox.position = Offset(
              _dragInitialX! + actualDeltaX,
              widget.textBox.position.dy,
            );
          } else {
            final newWidth = max(
              NoteTextBox.minWidth,
              _resizeInitialWidth! + deltaX,
            );
            widget.textBox.width = newWidth;
          }
          widget.controller.updateTextBox(widget.textBox);
        },
        onPanEnd: (_) {
          setState(() => _isResizing = false);
          _resizeStartX = null;
          widget.controller.commitTextBoxTransform();
        },
        child: Container(
          width: 24,
          color: Colors.transparent,
          alignment: Alignment.center,
          child: Container(
            width: 4,
            height: 26,
            decoration: BoxDecoration(
              color: const Color(0xFF007AFF),
              borderRadius: BorderRadius.circular(2),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF007AFF).withValues(alpha: 0.35),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
