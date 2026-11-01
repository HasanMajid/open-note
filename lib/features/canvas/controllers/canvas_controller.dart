import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:open_note/core/constants/app_constants.dart';
import 'package:open_note/core/theme/app_colors.dart';
import 'package:open_note/features/canvas/controllers/rich_text_editing_controller.dart';
import 'package:open_note/features/canvas/models/canvas_history_snapshot.dart';
import 'package:open_note/features/canvas/models/note_image.dart';
import 'package:open_note/features/canvas/models/note_text_box.dart';
import 'package:open_note/features/canvas/models/rich_text_span.dart';
import 'package:open_note/features/canvas/models/stroke.dart';
import 'package:open_note/features/canvas/models/stroke_point.dart';
import 'package:open_note/features/canvas/models/tool_type.dart';
import 'package:open_note/features/canvas/presentation/widgets/selection_toolbar.dart';
import 'package:open_note/features/canvas/services/clipboard_image_service.dart';
import 'package:open_note/features/canvas/services/eraser_service.dart';
import 'package:open_note/features/canvas/services/lasso_service.dart';
import 'package:open_note/features/canvas/models/canvas_mode.dart';
import 'package:open_note/features/notebook/models/note_page.dart';

class CanvasController extends ChangeNotifier {
  List<NotePage> _pages = [
    NotePage(id: 'page_1', pageNumber: 1),
  ];
  int _activePageIndex = 0;
  String? _activeTextBoxId;
  String? _selectedImageId;
  RichTextEditingController? _activeRichTextController;

  final List<CanvasHistorySnapshot> _undoStack = [];
  final List<CanvasHistorySnapshot> _redoStack = [];

  NotePage get activePage {
    if (_pages.isEmpty) {
      _pages = [NotePage(id: 'page_1', pageNumber: 1)];
      _activePageIndex = 0;
    }
    final idx = _activePageIndex.clamp(0, _pages.length - 1);
    return _pages[idx];
  }

  List<Stroke> get _strokes => activePage.strokes;
  set _strokes(List<Stroke> val) {
    activePage.strokes = val;
  }

  List<NoteTextBox> get _textBoxes => activePage.textBoxes;
  set _textBoxes(List<NoteTextBox> val) {
    activePage.textBoxes = val;
  }

  ToolType _activeTool = ToolType.pen;
  Color _penColor = Colors.black;
  Color _highlighterColor = AppColors.highlighterPalette.first;
  double _penWidth = AppConstants.defaultStrokeWidth;
  double _highlighterWidth = 22.0;
  double _eraserRadius = AppConstants.defaultEraserRadius;
  bool _isDrawing = false;

  // Palm Rejection & Multi-Touch State
  bool _isStylusActive = false;
  DateTime? _lastStylusTime;
  final Set<int> _activePointers = {};
  int? _drawingPointerId;
  bool _isMultiTouch = false;
  bool _eraserPendingTouch = false;
  Offset? _eraserTouchDownPos;
  List<Stroke>? _eraserGestureInitialStrokes;
  bool _eraserGestureDidModify = false;

  // Text Tool Tap State (defers creation until pointer-up to distinguish taps from multi-touch pinch/drag)
  Offset? _textTouchDownPos;
  double _textDragDistance = 0.0;

  // Selection / Lasso Tool State
  final ValueNotifier<List<Offset>> lassoPointsNotifier =
      ValueNotifier<List<Offset>>([]);
  List<Stroke> _selectedStrokes = [];
  Rect? _selectionBounds;
  LassoHandle _activeLassoHandle = LassoHandle.none;
  Offset? _lassoDragStartPos;
  Rect? _lassoInitialBounds;
  List<Stroke>? _lassoInitialSelectedStrokes;
  List<Stroke>? _lassoPreTransformAllStrokes;
  bool _lassoTransformDidModify = false;
  Offset? _lassoTouchDownPos;
  double _lassoDragDistance = 0.0;
  bool _pointerDownOnToolbar = false;
  Offset? _lassoRotationCenter;
  double? _lassoRotationStartAngle;
  double _selectionRotation = 0.0;
  double _lassoInitialRotation = 0.0;
  final List<int> _lassoSelectedIndices = [];

  /// Dedicated notifier for the single stroke in-progress to avoid repainting
  /// completed strokes during pen-move events.
  final ValueNotifier<List<StrokePoint>> currentStrokeNotifier =
      ValueNotifier<List<StrokePoint>>([]);

  /// Dedicated notifier for live eraser cursor ring position.
  final ValueNotifier<Offset?> eraserPointerNotifier =
      ValueNotifier<Offset?>(null);

  final List<Color> _customColors = [];

  List<Stroke> get strokes => List.unmodifiable(_strokes);
  List<NotePage> get pages => List.unmodifiable(_pages);
  int get activePageIndex => _activePageIndex;

  int _contentVersion = 0;
  /// Incremented whenever canvas content (strokes, text, images, pages) is modified.
  int get contentVersion => _contentVersion;

  void markContentChanged() {
    _contentVersion++;
  }

  void setActivePage(int index) {
    if (index < 0 || index >= _pages.length) return;
    if (_activePageIndex == index) return;
    deselect();
    _activePageIndex = index;
    notifyListeners();
  }

  CanvasMode _canvasMode = CanvasMode.paged;
  CanvasMode get canvasMode => _canvasMode;
  bool get isInfinite => _canvasMode == CanvasMode.infinite;

  void setCanvasMode(CanvasMode mode) {
    if (_canvasMode == mode) return;
    _recordHistory();
    _redoStack.clear();
    deselect();

    if (mode == CanvasMode.infinite) {
      // Transitioning to Infinite Canvas Mode:
      // Merge multiple pages into page 1 with their vertical spatial offsets preserved
      if (_pages.length > 1) {
        final List<Stroke> mergedStrokes = [];
        final List<NoteTextBox> mergedTextBoxes = [];
        final List<NoteImage> mergedImages = [];

        for (int i = 0; i < _pages.length; i++) {
          final p = _pages[i];
          final yOffset = AppConstants.pageHeaderHeight + i * AppConstants.pagePitch;

          for (final stroke in p.strokes) {
            mergedStrokes.add(stroke.copyWith(
              points: stroke.points
                  .map((pt) => pt.copyWith(dy: pt.dy + yOffset))
                  .toList(),
            ));
          }

          for (final box in p.textBoxes) {
            mergedTextBoxes.add(box.copyWith(
              position: Offset(box.position.dx, box.position.dy + yOffset),
            ));
          }

          for (final img in p.images) {
            mergedImages.add(img.copyWith(
              position: Offset(img.position.dx, img.position.dy + yOffset),
            ));
          }
        }

        _pages = [
          NotePage(
            id: _pages.first.id,
            pageNumber: 1,
            strokes: mergedStrokes,
            textBoxes: mergedTextBoxes,
            images: mergedImages,
          ),
        ];
        _activePageIndex = 0;
      }
    }

    _canvasMode = mode;
    _contentVersion++;
    notifyListeners();
  }

  void toggleCanvasMode() {
    setCanvasMode(
      _canvasMode == CanvasMode.paged ? CanvasMode.infinite : CanvasMode.paged,
    );
  }

  NotePage addPage() {
    if (_canvasMode == CanvasMode.infinite) {
      _canvasMode = CanvasMode.paged;
    }
    _recordHistory();
    _redoStack.clear();
    final newPage = NotePage(
      id: 'page_${DateTime.now().millisecondsSinceEpoch}',
      pageNumber: _pages.length + 1,
    );
    _pages = [..._pages, newPage];
    _activePageIndex = _pages.length - 1;
    notifyListeners();
    return newPage;
  }

  void deletePage(int index) {
    if (_pages.length <= 1) return;
    _recordHistory();
    _redoStack.clear();
    deselect();
    final updated = List<NotePage>.from(_pages);
    updated.removeAt(index);
    for (int i = 0; i < updated.length; i++) {
      updated[i] = updated[i].copyWith(pageNumber: i + 1);
    }
    _pages = updated;
    if (_activePageIndex >= _pages.length) {
      _activePageIndex = _pages.length - 1;
    }
    notifyListeners();
  }

  void loadPages(
    List<NotePage> pages, {
    CanvasMode mode = CanvasMode.paged,
    bool clearHistory = false,
  }) {
    if (clearHistory) {
      _undoStack.clear();
      _redoStack.clear();
    } else {
      _recordHistory();
      _redoStack.clear();
    }
    _canvasMode = mode;
    _pages = pages.isNotEmpty
        ? pages.map((p) => p.clone()).toList()
        : [NotePage(id: 'page_1', pageNumber: 1)];
    _activePageIndex = 0;
    _activeTextBoxId = null;
    _selectedImageId = null;
    _activeRichTextController = null;
    deselect();
    notifyListeners();
  }

  RichTextEditingController? get activeRichTextController =>
      _activeRichTextController;

  double _canvasScale = 1.0;
  double get canvasScale => _canvasScale;

  void setCanvasScale(double scale) {
    if ((_canvasScale - scale).abs() > 0.0001) {
      _canvasScale = scale;
    }
  }

  void setActiveRichTextController(RichTextEditingController? ctrl) {
    if (_activeRichTextController == ctrl) return;
    _activeRichTextController?.removeListener(_onRichTextControllerChanged);
    _activeRichTextController = ctrl;
    _activeRichTextController?.addListener(_onRichTextControllerChanged);
    notifyListeners();
  }

  void _onRichTextControllerChanged() {
    _contentVersion++;
    notifyListeners();
  }

  final Map<HeadingLevel, double> _preferredHeadingFontSizes = {
    HeadingLevel.none: 15.0,
    HeadingLevel.h1: 26.0,
    HeadingLevel.h2: 20.0,
    HeadingLevel.h3: 17.0,
  };

  double get preferredFontSize =>
      _preferredHeadingFontSizes[HeadingLevel.none] ?? 15.0;

  Map<HeadingLevel, double> get preferredHeadingFontSizes =>
      Map.unmodifiable(_preferredHeadingFontSizes);

  double defaultFontSizeForHeading(HeadingLevel heading) =>
      _preferredHeadingFontSizes[heading] ?? heading.defaultFontSize;

  void setPreferredFontSize(double size) {
    setPreferredFontSizeForHeading(HeadingLevel.none, size);
  }

  void setPreferredFontSizeForHeading(HeadingLevel heading, double size) {
    if (_preferredHeadingFontSizes[heading] == size) return;
    _preferredHeadingFontSizes[heading] = size;
    _activeRichTextController?.setDefaultFontSizeForHeading(heading, size);
    final box = activeTextBox;
    if (box != null) {
      box.headingDefaultFontSizes ??= Map.from(_preferredHeadingFontSizes);
      box.headingDefaultFontSizes![heading] = size;
      if (heading == HeadingLevel.none) {
        box.defaultFontSize = size;
      }
      updateTextBox(box);
    }
    notifyListeners();
  }

  HeadingLevel _activeTextHeading = HeadingLevel.none;
  bool _activeTextBold = false;
  bool _activeTextItalic = false;
  bool _activeTextUnderline = false;
  bool _activeTextStrikethrough = false;
  double? _activeTextFontSize;
  Color? _activeTextColor;
  Color? _activeTextHighlight;

  HeadingLevel get activeTextHeading =>
      _activeRichTextController?.currentHeading ?? _activeTextHeading;
  bool get activeTextBold =>
      _activeRichTextController?.isSelectionBold ?? _activeTextBold;
  bool get activeTextItalic =>
      _activeRichTextController?.isSelectionItalic ?? _activeTextItalic;
  bool get activeTextUnderline =>
      _activeRichTextController?.isSelectionUnderline ?? _activeTextUnderline;
  bool get activeTextStrikethrough =>
      _activeRichTextController?.isSelectionStrikethrough ?? _activeTextStrikethrough;
  double get activeTextFontSize {
    if (_activeRichTextController != null) {
      return _activeRichTextController!.activeFontSize;
    }
    if (_activeTextFontSize != null) return _activeTextFontSize!;
    return defaultFontSizeForHeading(activeTextHeading);
  }
  Color? get activeTextColor =>
      _activeRichTextController?.currentTextColor ?? _activeTextColor;
  Color? get activeTextHighlight =>
      _activeRichTextController?.currentHighlightColor ?? _activeTextHighlight;

  void setFontSize(double size) {
    _activeTextFontSize = size;
    final ctrl = _activeRichTextController;
    if (ctrl != null) {
      final sel = ctrl.effectiveSelection;
      if (!sel.isCollapsed && sel.start < sel.end) {
        ctrl.setFontSize(size);
      } else {
        ctrl.setFontSize(size);
        final box = activeTextBox;
        if (box != null) {
          box.defaultFontSize = size;
          if (box.spans.isEmpty) {
            // Unstyled body text updates directly via defaultFontSize
          } else if (sel.baseOffset < 0) {
            // Box selected as a whole on canvas: update all text spans
            ctrl.selection =
                TextSelection(baseOffset: 0, extentOffset: ctrl.text.length);
            ctrl.setFontSize(size);
            ctrl.selection = const TextSelection.collapsed(offset: -1);
          }
          updateTextBox(box);
        }
      }
    } else {
      final box = activeTextBox;
      if (box != null) {
        box.defaultFontSize = size;
        updateTextBox(box);
      }
    }
    notifyListeners();
  }

  void toggleBold() {
    if (_activeRichTextController != null) {
      _activeRichTextController!.toggleBold();
      _activeTextBold = _activeRichTextController!.isSelectionBold;
    } else {
      _activeTextBold = !_activeTextBold;
    }
    notifyListeners();
  }

  void toggleItalic() {
    if (_activeRichTextController != null) {
      _activeRichTextController!.toggleItalic();
      _activeTextItalic = _activeRichTextController!.isSelectionItalic;
    } else {
      _activeTextItalic = !_activeTextItalic;
    }
    notifyListeners();
  }

  void toggleUnderline() {
    if (_activeRichTextController != null) {
      _activeRichTextController!.toggleUnderline();
      _activeTextUnderline = _activeRichTextController!.isSelectionUnderline;
    } else {
      _activeTextUnderline = !_activeTextUnderline;
    }
    notifyListeners();
  }

  void toggleStrikethrough() {
    if (_activeRichTextController != null) {
      _activeRichTextController!.toggleStrikethrough();
      _activeTextStrikethrough = _activeRichTextController!.isSelectionStrikethrough;
    } else {
      _activeTextStrikethrough = !_activeTextStrikethrough;
    }
    notifyListeners();
  }

  void setHeading(HeadingLevel heading) {
    _activeTextHeading = heading;
    _activeTextFontSize = null;
    if (_activeRichTextController != null) {
      _activeRichTextController!.setHeading(heading);
      _activeTextHeading = _activeRichTextController!.currentHeading;
    }
    notifyListeners();
  }

  void setTextColor(Color color) {
    if (_activeRichTextController != null) {
      _activeRichTextController!.setTextColor(color);
      _activeTextColor = _activeRichTextController!.currentTextColor;
    } else {
      _activeTextColor = color;
    }
    notifyListeners();
  }

  void setTextHighlight(Color? color) {
    if (_activeRichTextController != null) {
      _activeRichTextController!.setTextHighlight(color);
      _activeTextHighlight = _activeRichTextController!.currentHighlightColor;
    } else {
      _activeTextHighlight = color;
    }
    notifyListeners();
  }

  void deleteActiveTextBox() {
    if (_activeTextBoxId != null) {
      deleteTextBox(_activeTextBoxId!);
    }
  }

  void unfocusActiveTextBox() {
    selectTextBox(null);
    setActiveRichTextController(null);
  }

  bool get isCurrentTextRtl {
    if (activeTextBox == null) return false;
    if (activeTextBox!.textDirection != null) {
      return activeTextBox!.textDirection == TextDirection.rtl;
    }
    final text = _activeRichTextController?.text ?? activeTextBox!.text;
    return NoteTextBox.isRtlText(text);
  }

  void toggleTextDirection() {
    final box = activeTextBox;
    if (box == null) return;
    final isRtl = isCurrentTextRtl;
    box.textDirection = isRtl ? TextDirection.ltr : TextDirection.rtl;
    updateTextBox(box);
    notifyListeners();
  }

  void setTextDirection(TextDirection? direction) {
    final box = activeTextBox;
    if (box == null) return;
    box.textDirection = direction;
    updateTextBox(box);
    notifyListeners();
  }

  List<NoteTextBox> get textBoxes => List.unmodifiable(_textBoxes);
  String? get activeTextBoxId => _activeTextBoxId;
  NoteTextBox? get activeTextBox {
    if (_activeTextBoxId == null) return null;
    for (final page in _pages) {
      for (final box in page.textBoxes) {
        if (box.id == _activeTextBoxId) return box;
      }
    }
    return null;
  }

  bool _isDarkMode = false;
  bool get isDarkMode => _isDarkMode;

  void toggleDarkMode() {
    _isDarkMode = !_isDarkMode;
    notifyListeners();
  }

  void setDarkMode(bool value) {
    if (_isDarkMode == value) return;
    _isDarkMode = value;
    notifyListeners();
  }

  /// Returns true if a color is black or very near-black (e.g. #000000, #111111, #212121).
  /// Excludes highlighters and chromatic colors (e.g. purple, blue, red) by checking saturation.
  static bool isNearBlack(Color color) {
    if (color.a < 0.5) return false;
    final hsv = HSVColor.fromColor(color);
    return hsv.value < 0.25 && hsv.saturation < 0.25;
  }

  /// Returns the display color of a stroke on screen, dynamically converting black ink
  /// to crisp white on dark paper while preserving original color data.
  Color getDisplayStrokeColor(Color color) {
    if (_isDarkMode && isNearBlack(color)) {
      return Colors.white;
    }
    return color;
  }

  List<Color> get customColors => List.unmodifiable(_customColors);
  ToolType get activeTool => _activeTool;
  Color get activeColor =>
      _activeTool == ToolType.highlighter ? _highlighterColor : _penColor;
  double get strokeWidth =>
      _activeTool == ToolType.highlighter ? _highlighterWidth : _penWidth;
  double get eraserRadius => _eraserRadius;
  bool get isDrawing => _isDrawing;
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  bool get isStylusActive => _isStylusActive;
  bool get isMultiTouch => _isMultiTouch;

  List<Stroke> get selectedStrokes => List.unmodifiable(_selectedStrokes);
  bool get hasSelection => _selectedStrokes.isNotEmpty;
  Rect? get selectionBounds => _selectionBounds;
  double get selectionRotation => _selectionRotation;
  bool get isTransforming => _activeLassoHandle != LassoHandle.none;

  static const int _w3cEraserButton = 32;

  bool _isStylusButtonPressed(int buttons) {
    return (buttons & _w3cEraserButton != 0) ||
        (buttons & kPrimaryStylusButton != 0) ||
        (buttons & kSecondaryButton != 0) ||
        (buttons & kSecondaryStylusButton != 0);
  }

  bool _isEraserActive(int buttons, PointerDeviceKind? kind) {
    return _activeTool.isEraser ||
        kind == PointerDeviceKind.invertedStylus ||
        _isStylusButtonPressed(buttons);
  }

  void _cleanUpEmptyTextBoxes({String? exceptId}) {
    for (final page in _pages) {
      page.textBoxes = page.textBoxes.where((box) {
        if (box.id == exceptId) return true;
        return box.text.trim().isNotEmpty;
      }).toList();
    }
  }

  void selectTextBox(String? id) {
    if (id != null && _activeTool != ToolType.text) return;
    if (_activeTextBoxId == id) return;
    _cleanUpEmptyTextBoxes(exceptId: id);
    _activeTextBoxId = id;
    if (id != null) {
      _selectedImageId = null;
    }
    if (id == null) {
      setActiveRichTextController(null);
    }
    notifyListeners();
  }

  static int _nextTextBoxId = 0;

  NoteTextBox addTextBox(
    Offset position, {
    String text = '',
    double width = 300.0,
    int? pageIndex,
  }) {
    _cleanUpEmptyTextBoxes();
    _recordHistory();
    _redoStack.clear();
    final targetPage = pageIndex != null &&
            pageIndex >= 0 &&
            pageIndex < _pages.length
        ? _pages[pageIndex]
        : activePage;
    final newBox = NoteTextBox(
      id: 'box_${DateTime.now().microsecondsSinceEpoch}_${_nextTextBoxId++}',
      position: position,
      width: width,
      text: text,
      defaultFontSize: defaultFontSizeForHeading(HeadingLevel.none),
      headingDefaultFontSizes: Map.from(_preferredHeadingFontSizes),
    );
    targetPage.textBoxes = [...targetPage.textBoxes, newBox];
    _activeTextBoxId = newBox.id;
    notifyListeners();
    return newBox;
  }

  void updateTextBox(NoteTextBox updated) {
    for (final page in _pages) {
      final idx = page.textBoxes.indexWhere((b) => b.id == updated.id);
      if (idx != -1) {
        final newBoxes = List<NoteTextBox>.from(page.textBoxes);
        newBoxes[idx] = updated;
        page.textBoxes = newBoxes;
        notifyListeners();
        return;
      }
    }
  }

  void updateTextBoxPosition(String id, Offset newPosition) {
    for (final page in _pages) {
      final idx = page.textBoxes.indexWhere((b) => b.id == id);
      if (idx != -1) {
        page.textBoxes[idx].position = newPosition;
        notifyListeners();
        return;
      }
    }
  }

  void transferTextBoxIfNeeded(String id) {
    if (_pages.length <= 1) return;

    int sourcePageIndex = -1;
    NoteTextBox? box;
    for (int i = 0; i < _pages.length; i++) {
      for (final b in _pages[i].textBoxes) {
        if (b.id == id) {
          sourcePageIndex = i;
          box = b;
          break;
        }
      }
      if (box != null) break;
    }
    if (box == null || sourcePageIndex == -1) return;

    final centerGlobalY = AppConstants.pageHeaderHeight +
        sourcePageIndex * AppConstants.pagePitch +
        box.position.dy +
        (box.height ?? 44.0) / 2;
    final targetPageIndex = (centerGlobalY / AppConstants.pagePitch)
        .floor()
        .clamp(0, _pages.length - 1);

    if (targetPageIndex != sourcePageIndex) {
      final yShift =
          (sourcePageIndex - targetPageIndex) * AppConstants.pagePitch;
      _pages[sourcePageIndex].textBoxes =
          _pages[sourcePageIndex].textBoxes.where((b) => b.id != id).toList();

      box.position = Offset(box.position.dx, box.position.dy + yShift);
      _pages[targetPageIndex].textBoxes = [
        ..._pages[targetPageIndex].textBoxes,
        box,
      ];
      _activePageIndex = targetPageIndex;
      notifyListeners();
    }
  }

  void beginTextBoxTransform() {
    _recordHistory();
    _redoStack.clear();
  }

  void commitTextBoxTransform() {
    notifyListeners();
  }

  void deleteTextBox(String id) {
    _recordHistory();
    _redoStack.clear();
    for (final page in _pages) {
      page.textBoxes = page.textBoxes.where((b) => b.id != id).toList();
    }
    if (_activeTextBoxId == id) {
      _activeTextBoxId = null;
      _activeRichTextController = null;
    }
    notifyListeners();
  }

  void loadTextBoxes(List<NoteTextBox> boxes) {
    _textBoxes = List.from(boxes);
    _activeTextBoxId = null;
    _activeRichTextController = null;
    notifyListeners();
  }

  static int _nextImageId = 0;

  List<NoteImage> get images => activePage.images;
  String? get selectedImageId => _selectedImageId;
  NoteImage? get selectedImage {
    if (_selectedImageId == null) return null;
    for (final page in _pages) {
      for (final img in page.images) {
        if (img.id == _selectedImageId) return img;
      }
    }
    return null;
  }

  void selectImage(String? id) {
    if (_selectedImageId == id) return;
    _selectedImageId = id;
    if (id != null) {
      _activeTextBoxId = null;
      setActiveRichTextController(null);
      if (_activeTool != ToolType.text && _activeTool != ToolType.lasso) {
        _activeTool = ToolType.lasso;
      }
    }
    notifyListeners();
  }

  Future<NoteImage> addImage(
    Uint8List bytes, {
    Offset? position,
    double? width,
    double? height,
    int? pageIndex,
    String? name,
  }) async {
    _recordHistory();
    _redoStack.clear();

    final targetPage = pageIndex != null &&
            pageIndex >= 0 &&
            pageIndex < _pages.length
        ? _pages[pageIndex]
        : activePage;

    double displayWidth = width ?? 350.0;
    double displayHeight = height ?? 250.0;

    if (width == null || height == null) {
      final naturalSize = await ClipboardImageService.getImageSize(bytes);
      if (naturalSize.width > 0 && naturalSize.height > 0) {
        if (naturalSize.width > 450.0) {
          displayWidth = 450.0;
          displayHeight = (450.0 / naturalSize.width) * naturalSize.height;
        } else {
          displayWidth = max(naturalSize.width, 100.0);
          displayHeight = max(naturalSize.height, 60.0);
        }
      }
    }

    final targetPos = position ??
        Offset(
          max(20.0, (AppConstants.defaultPageSize.width - displayWidth) / 2.0),
          120.0,
        );

    final newImage = NoteImage(
      id: 'img_${DateTime.now().microsecondsSinceEpoch}_${_nextImageId++}',
      position: targetPos,
      width: displayWidth,
      height: displayHeight,
      bytes: bytes,
      name: name,
    );

    targetPage.images = [...targetPage.images, newImage];
    _selectedImageId = newImage.id;
    _activeTextBoxId = null;
    if (_activeTool != ToolType.text && _activeTool != ToolType.lasso) {
      _activeTool = ToolType.lasso;
    }
    notifyListeners();
    return newImage;
  }

  void updateImage(NoteImage updated) {
    for (final page in _pages) {
      final idx = page.images.indexWhere((img) => img.id == updated.id);
      if (idx != -1) {
        final newImages = List<NoteImage>.from(page.images);
        newImages[idx] = updated;
        page.images = newImages;
        notifyListeners();
        return;
      }
    }
  }

  void updateImagePosition(String id, Offset newPosition) {
    for (final page in _pages) {
      final idx = page.images.indexWhere((img) => img.id == id);
      if (idx != -1) {
        page.images[idx].position = newPosition;
        notifyListeners();
        return;
      }
    }
  }

  void updateImageSize(String id, double newWidth, double newHeight) {
    for (final page in _pages) {
      final idx = page.images.indexWhere((img) => img.id == id);
      if (idx != -1) {
        page.images[idx].width = newWidth;
        page.images[idx].height = newHeight;
        notifyListeners();
        return;
      }
    }
  }

  void deleteImage(String id) {
    _recordHistory();
    _redoStack.clear();
    for (final page in _pages) {
      page.images = page.images.where((img) => img.id != id).toList();
    }
    if (_selectedImageId == id) {
      _selectedImageId = null;
    }
    notifyListeners();
  }

  void bringImageToFront(String id) {
    for (final page in _pages) {
      final idx = page.images.indexWhere((img) => img.id == id);
      if (idx != -1 && idx < page.images.length - 1) {
        _recordHistory();
        _redoStack.clear();
        final img = page.images.removeAt(idx);
        page.images.add(img);
        notifyListeners();
        return;
      }
    }
  }

  void sendImageToBack(String id) {
    for (final page in _pages) {
      final idx = page.images.indexWhere((img) => img.id == id);
      if (idx > 0) {
        _recordHistory();
        _redoStack.clear();
        final img = page.images.removeAt(idx);
        page.images.insert(0, img);
        notifyListeners();
        return;
      }
    }
  }

  void transferImageIfNeeded(String id) {
    if (_pages.length <= 1) return;

    int sourcePageIndex = -1;
    NoteImage? image;
    for (int i = 0; i < _pages.length; i++) {
      for (final img in _pages[i].images) {
        if (img.id == id) {
          sourcePageIndex = i;
          image = img;
          break;
        }
      }
      if (image != null) break;
    }
    if (image == null || sourcePageIndex == -1) return;

    final centerGlobalY = AppConstants.pageHeaderHeight +
        sourcePageIndex * AppConstants.pagePitch +
        image.position.dy +
        image.height / 2;
    final targetPageIndex = (centerGlobalY / AppConstants.pagePitch)
        .floor()
        .clamp(0, _pages.length - 1);

    if (targetPageIndex != sourcePageIndex) {
      final yShift =
          (sourcePageIndex - targetPageIndex) * AppConstants.pagePitch;
      _pages[sourcePageIndex].images =
          _pages[sourcePageIndex].images.where((img) => img.id != id).toList();

      image.position = Offset(image.position.dx, image.position.dy + yShift);
      _pages[targetPageIndex].images = [
        ..._pages[targetPageIndex].images,
        image,
      ];
      _activePageIndex = targetPageIndex;
      notifyListeners();
    }
  }

  void beginImageTransform() {
    _recordHistory();
    _redoStack.clear();
  }

  void commitImageTransform() {
    notifyListeners();
  }

  Future<bool> pasteImageFromClipboard({Offset? targetPosition}) async {
    final bytes = await ClipboardImageService.readImageFromClipboard();
    if (bytes != null && bytes.isNotEmpty) {
      await addImage(bytes, position: targetPosition);
      return true;
    }
    return false;
  }

  Future<bool> pickAndInsertImage({Offset? targetPosition}) async {
    final picked = await ClipboardImageService.pickImageFile();
    if (picked != null && picked.bytes.isNotEmpty) {
      await addImage(
        picked.bytes,
        position: targetPosition,
        name: picked.name,
      );
      return true;
    }
    return false;
  }

  void setTool(ToolType tool) {
    if (_activeTool == tool) return;
    if (_activeTool == ToolType.lasso) {
      deselect();
    }
    if (tool != ToolType.text && tool != ToolType.lasso) {
      unfocusActiveTextBox();
      _selectedImageId = null;
      _textTouchDownPos = null;
      _textDragDistance = 0.0;
    }
    _activeTool = tool;
    _isDrawing = false;
    _eraserPendingTouch = false;
    if (_eraserGestureDidModify && _eraserGestureInitialStrokes != null) {
      _recordSnapshot(_eraserGestureInitialStrokes!);
      _redoStack.clear();
    }
    _eraserGestureInitialStrokes = null;
    _eraserGestureDidModify = false;
    currentStrokeNotifier.value = [];
    notifyListeners();
  }

  void setColor(Color color) {
    if (hasSelection) {
      recolorSelection(color);
      return;
    }
    if (_activeTool == ToolType.highlighter) {
      final adjusted = color.a >= 1.0 ? color.withValues(alpha: 0.38) : color;
      if (_highlighterColor == adjusted) return;
      _highlighterColor = adjusted;
    } else {
      if (_penColor == color) return;
      _penColor = color;
    }
    notifyListeners();
  }

  void deselect() {
    if (!hasSelection && lassoPointsNotifier.value.isEmpty) return;
    _selectedStrokes = [];
    _selectionBounds = null;
    _selectionRotation = 0.0;
    _lassoInitialRotation = 0.0;
    _activeLassoHandle = LassoHandle.none;
    _lassoInitialSelectedStrokes = null;
    _lassoPreTransformAllStrokes = null;
    _lassoTransformDidModify = false;
    _lassoRotationCenter = null;
    _lassoRotationStartAngle = null;
    _lassoSelectedIndices.clear();
    lassoPointsNotifier.value = [];
    notifyListeners();
  }

  void deleteSelection() {
    if (!hasSelection) return;
    _recordHistory();
    final toRemove = _selectedStrokes.toSet();
    for (final page in _pages) {
      page.strokes = page.strokes.where((s) => !toRemove.contains(s)).toList();
    }
    _selectedStrokes = [];
    _selectionBounds = null;
    _selectionRotation = 0.0;
    _lassoInitialRotation = 0.0;
    _activeLassoHandle = LassoHandle.none;
    _redoStack.clear();
    notifyListeners();
  }

  void duplicateSelection() {
    if (!hasSelection || _selectionBounds == null) return;
    _recordHistory();
    final offset = LassoService.computeDuplicateOffset(
      _selectionBounds!,
      pageWidth: AppConstants.defaultPageSize.width,
      pageHeight: AppConstants.defaultPageSize.height,
    );
    final duplicated = LassoService.translateStrokes(
      _selectedStrokes,
      offset,
    );
    _strokes = [..._strokes, ...duplicated];
    _selectedStrokes = duplicated;
    _selectionBounds = _selectionBounds!.shift(offset);
    _redoStack.clear();
    notifyListeners();
  }

  void rotateSelection90({bool clockwise = true}) {
    if (!hasSelection || _selectionBounds == null) return;
    _recordHistory();
    final angle = clockwise ? (pi / 2) : (-pi / 2);
    final center = _selectionBounds!.center;
    final rotated = LassoService.rotateStrokes(
      _selectedStrokes,
      center,
      angle,
    );
    final oldSelectedSet = _selectedStrokes.toSet();
    final List<Stroke> newStrokes = [];
    int selIdx = 0;
    for (final s in _strokes) {
      if (oldSelectedSet.contains(s)) {
        newStrokes.add(rotated[selIdx++]);
      } else {
        newStrokes.add(s);
      }
    }
    _strokes = newStrokes;
    _selectedStrokes = rotated;
    _selectionRotation += angle;
    while (_selectionRotation > pi) {
      _selectionRotation -= 2 * pi;
    }
    while (_selectionRotation < -pi) {
      _selectionRotation += 2 * pi;
    }
    _redoStack.clear();
    notifyListeners();
  }

  void recolorSelection(Color color) {
    if (!hasSelection) return;
    _recordHistory();
    final recolored =
        _selectedStrokes.map((s) => s.copyWith(color: color)).toList();
    final oldSelectedSet = _selectedStrokes.toSet();
    final List<Stroke> newStrokes = [];
    int selIdx = 0;
    for (final s in _strokes) {
      if (oldSelectedSet.contains(s)) {
        newStrokes.add(recolored[selIdx++]);
      } else {
        newStrokes.add(s);
      }
    }
    _strokes = newStrokes;
    _selectedStrokes = recolored;
    _redoStack.clear();
    notifyListeners();
  }

  void addCustomColor(Color color) {
    _customColors.removeWhere((c) => c.toARGB32() == color.toARGB32());
    _customColors.insert(0, color);
    if (_customColors.length > 5) {
      _customColors.removeLast();
    }
    setColor(color);
  }

  void setStrokeWidth(double width) {
    if (_activeTool == ToolType.highlighter) {
      if (_highlighterWidth == width) return;
      _highlighterWidth = width;
    } else {
      if (_penWidth == width) return;
      _penWidth = width;
    }
    notifyListeners();
  }

  void setEraserRadius(double radius) {
    if (_eraserRadius == radius) return;
    _eraserRadius = radius;
    notifyListeners();
  }

  void clearHistory() {
    _undoStack.clear();
    _redoStack.clear();
    notifyListeners();
  }

  void loadStrokes(List<Stroke> newStrokes, {bool clearHistory = false}) {
    if (clearHistory) {
      _undoStack.clear();
      _redoStack.clear();
    } else {
      _recordHistory();
      _redoStack.clear();
    }
    _strokes = List.from(newStrokes);
    notifyListeners();
  }

  void onPointerDown(
    Offset localPosition, {
    int pointer = 0,
    PointerDeviceKind? kind,
    double pressure = 0.5,
    int buttons = 0,
  }) {
    if (_activeTool == ToolType.pan) return;

    // 1. Palm Rejection: If stylus is active, ignore touch pointers before tracking them
    if (kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus) {
      _isStylusActive = true;
      _lastStylusTime = DateTime.now();
    } else if (kind == PointerDeviceKind.touch && _isStylusActive) {
      if (_lastStylusTime != null &&
          DateTime.now().difference(_lastStylusTime!).inMilliseconds < 1500) {
        return; // Reject palm touch
      } else {
        _isStylusActive = false;
      }
    }

    _activePointers.add(pointer);

    // 2. Multi-touch rejection (Pinch-to-zoom / 2-finger pan)
    if (_activePointers.length >= 2) {
      _isMultiTouch = true;
      _eraserPendingTouch = false;
      _eraserTouchDownPos = null;
      if (_isDrawing) {
        _isDrawing = false;
        currentStrokeNotifier.value = [];
      }
      _drawingPointerId = null;
      return;
    }

    if (_isMultiTouch) return;

    // Unfocus active text box if clicking outside with a different tool
    if (_activeTextBoxId != null && _activeTool != ToolType.text) {
      final box = activeTextBox;
      if (box == null || !box.bounds.inflate(28.0).contains(localPosition)) {
        unfocusActiveTextBox();
      }
    }

    // Text box tool handling: Defer tap execution to pointer up so multi-touch pinch-to-zoom
    // or pan gestures do not prematurely spawn a text box or summon the mobile virtual keyboard.
    if (_activeTool == ToolType.text) {
      _drawingPointerId = pointer;
      _textTouchDownPos = localPosition;
      _textDragDistance = 0.0;
      return;
    }

    // 3. Eraser handling (Eraser tool, inverted stylus tail, or stylus barrel/eraser button)
    if (_isEraserActive(buttons, kind)) {
      eraserPointerNotifier.value = localPosition;
      _eraserGestureInitialStrokes = List.from(_strokes);
      _eraserGestureDidModify = false;
      if (kind == PointerDeviceKind.touch && !_isStylusButtonPressed(buttons)) {
        // Defer touch erasure to move or up to prevent accidental erasure
        // when placing 2 fingers down for zoom/pan
        _drawingPointerId = pointer;
        _eraserPendingTouch = true;
        _eraserTouchDownPos = localPosition;
      } else {
        // Stylus or Mouse: erase immediately
        _handleEraser(localPosition);
      }
      return;
    }

    // 5. Lasso handling
    if (_activeTool == ToolType.lasso) {
      _pointerDownOnToolbar = false;
      _drawingPointerId = pointer;
      _lassoTouchDownPos = localPosition;
      _lassoDragDistance = 0.0;

      if (hasSelection && _selectionBounds != null) {
        // Priority 1: Check handles first! (Rotation knob or 4 corner resize handles)
        Offset effectivePos = localPosition;
        if (_selectionRotation != 0.0) {
          effectivePos = LassoService.unrotatePoint(
            localPosition,
            _selectionBounds!.center,
            _selectionRotation,
          );
        }

        final handle = LassoService.hitTestHandle(
          effectivePos,
          _selectionBounds!,
        );

        if (handle != LassoHandle.none && handle != LassoHandle.move) {
          _activeLassoHandle = handle;
          _lassoDragStartPos = localPosition;
          _lassoInitialBounds = _selectionBounds;
          _lassoInitialSelectedStrokes = List.from(_selectedStrokes);
          _lassoPreTransformAllStrokes = List.from(_strokes);
          _lassoTransformDidModify = false;
          _lassoInitialRotation = _selectionRotation;
          _lassoSelectedIndices.clear();
          final selSet = _selectedStrokes.toSet();
          for (int i = 0; i < _strokes.length; i++) {
            if (selSet.contains(_strokes[i])) {
              _lassoSelectedIndices.add(i);
            }
          }

          if (handle == LassoHandle.rotate) {
            final center = _selectionBounds!.center;
            _lassoRotationCenter = center;
            _lassoRotationStartAngle = atan2(
              localPosition.dy - center.dy,
              localPosition.dx - center.dx,
            );
          } else {
            _lassoRotationCenter = null;
            _lassoRotationStartAngle = null;
          }
          notifyListeners();
          return;
        }

        // Priority 2: Floating contextual toolbar
        final toolbarRect = SelectionToolbar.getToolbarRect(
          _selectionBounds!,
          rotationAngle: _selectionRotation,
        );

        if (toolbarRect.contains(localPosition)) {
          // Tap is on the floating action toolbar: do not disrupt button clicks
          _pointerDownOnToolbar = true;
          return;
        }

        // Priority 3: Move handle (inside selection bounds)
        if (handle == LassoHandle.move) {
          _activeLassoHandle = handle;
          _lassoDragStartPos = localPosition;
          _lassoInitialBounds = _selectionBounds;
          _lassoInitialSelectedStrokes = List.from(_selectedStrokes);
          _lassoPreTransformAllStrokes = List.from(_strokes);
          _lassoTransformDidModify = false;
          _lassoInitialRotation = _selectionRotation;
          _lassoSelectedIndices.clear();
          final selSet = _selectedStrokes.toSet();
          for (int i = 0; i < _strokes.length; i++) {
            if (selSet.contains(_strokes[i])) {
              _lassoSelectedIndices.add(i);
            }
          }
          _lassoRotationCenter = null;
          _lassoRotationStartAngle = null;
          notifyListeners();
          return;
        }
      }

      _activeLassoHandle = LassoHandle.none;
      _lassoDragStartPos = null;
      _lassoRotationCenter = null;
      _lassoRotationStartAngle = null;
      _lassoSelectedIndices.clear();
      lassoPointsNotifier.value = [localPosition];
      return;
    }

    // 6. Inking
    _drawingPointerId = pointer;
    _isDrawing = true;
    final point = StrokePoint(
      localPosition.dx,
      localPosition.dy,
      pressure: pressure > 0.0 ? pressure : 0.5,
    );
    currentStrokeNotifier.value = [point];
  }

  void onPointerMove(
    Offset localPosition, {
    int pointer = 0,
    PointerDeviceKind? kind,
    double pressure = 0.5,
    int buttons = 0,
  }) {
    if (_activeTool == ToolType.pan) return;
    if (_isMultiTouch || _activePointers.length >= 2) return;
    if (kind == PointerDeviceKind.touch && _isStylusActive) return; // Palm rejection
    if (_drawingPointerId != null && _drawingPointerId != pointer) return;

    if (_activeTool == ToolType.text) {
      if (_textTouchDownPos != null) {
        _textDragDistance += (localPosition - _textTouchDownPos!).distance;
      }
      return;
    }

    // S-Pen barrel button: instantly acts as an eraser while held
    // 3. Eraser handling (Eraser tool, inverted stylus tail, or stylus barrel/eraser button)
    if (_isEraserActive(buttons, kind)) {
      if (_isDrawing) {
        _isDrawing = false;
        currentStrokeNotifier.value = [];
      }
      _eraserGestureInitialStrokes ??= List.from(_strokes);
      eraserPointerNotifier.value = localPosition;
      _eraserPendingTouch = false;
      _handleEraser(localPosition);
      return;
    }

    // Lasso Move or Scale or Drawing loop
    if (_activeTool == ToolType.lasso) {
      if (_lassoTouchDownPos != null) {
        _lassoDragDistance += (localPosition - _lassoTouchDownPos!).distance;
      }

      if (_activeLassoHandle != LassoHandle.none &&
          _lassoDragStartPos != null &&
          _lassoInitialBounds != null &&
          _lassoInitialSelectedStrokes != null) {
        _lassoTransformDidModify = true;
        final delta = localPosition - _lassoDragStartPos!;

        late final Rect updatedBounds;
        late final List<Stroke> updatedSelected;

        if (_activeLassoHandle == LassoHandle.rotate &&
            _lassoRotationCenter != null &&
            _lassoRotationStartAngle != null) {
          _lassoTransformDidModify = true;
          final currentAngle = atan2(
            localPosition.dy - _lassoRotationCenter!.dy,
            localPosition.dx - _lassoRotationCenter!.dx,
          );
          var angleDelta = currentAngle - _lassoRotationStartAngle!;
          while (angleDelta > pi) {
            angleDelta -= 2 * pi;
          }
          while (angleDelta < -pi) {
            angleDelta += 2 * pi;
          }

          var totalRotation = _lassoInitialRotation + angleDelta;

          // Angle snapping: snap totalRotation to 15-degree increments if within 3.5 degrees
          const snapThreshold = 3.5 * pi / 180.0;
          const snapStep = 15.0 * pi / 180.0;
          final nearestSnap = (totalRotation / snapStep).round() * snapStep;
          if ((totalRotation - nearestSnap).abs() < snapThreshold) {
            totalRotation = nearestSnap;
            angleDelta = totalRotation - _lassoInitialRotation;
          }

          updatedSelected = LassoService.rotateStrokes(
            _lassoInitialSelectedStrokes!,
            _lassoRotationCenter!,
            angleDelta,
          );
          _selectionRotation = totalRotation;
          updatedBounds = _lassoInitialBounds!;
        } else if (_activeLassoHandle == LassoHandle.move) {
          updatedBounds = _lassoInitialBounds!.shift(delta);
          updatedSelected = LassoService.translateStrokes(
            _lassoInitialSelectedStrokes!,
            delta,
          );
        } else {
          updatedBounds = LassoService.calculateTransformedBounds(
            _lassoInitialBounds!,
            _activeLassoHandle,
            delta,
          );
          updatedSelected = LassoService.scaleStrokes(
            _lassoInitialSelectedStrokes!,
            _lassoInitialBounds!,
            updatedBounds,
          );
        }

        final List<Stroke> newStrokes = List.from(_lassoPreTransformAllStrokes!);
        for (int i = 0; i < _lassoSelectedIndices.length; i++) {
          final idx = _lassoSelectedIndices[i];
          if (idx < newStrokes.length && i < updatedSelected.length) {
            newStrokes[idx] = updatedSelected[i];
          }
        }
        _strokes = newStrokes;
        _selectedStrokes = updatedSelected;
        _selectionBounds = updatedBounds;
        notifyListeners();
        return;
      }

      final current = lassoPointsNotifier.value;
      if (current.isNotEmpty && (current.last - localPosition).distance > 2.0) {
        lassoPointsNotifier.value = [...current, localPosition];
      }
      return;
    }

    if (!_isDrawing) return;

    final current = currentStrokeNotifier.value;
    if (current.isEmpty || (current.last - localPosition).distance > 1.0) {
      final point = StrokePoint(
        localPosition.dx,
        localPosition.dy,
        pressure: pressure > 0.0 ? pressure : 0.5,
      );
      currentStrokeNotifier.value = [...current, point];
    }
  }

  void onPointerUp(
    Offset localPosition, {
    int pointer = 0,
    PointerDeviceKind? kind,
    double pressure = 0.5,
    int buttons = 0,
  }) {
    _activePointers.remove(pointer);
    eraserPointerNotifier.value = null;

    if (_isMultiTouch) {
      if (_activePointers.isEmpty) {
        _isMultiTouch = false;
      }
      return;
    }

    if (_activeTool == ToolType.pan) return;
    if (kind == PointerDeviceKind.touch && _isStylusActive) return;
    if (_drawingPointerId != null && _drawingPointerId != pointer) return;
    _drawingPointerId = null;

    // 3. Eraser handling (Eraser tool, inverted stylus tail, or stylus barrel/eraser button)
    final wasErasing = _eraserGestureInitialStrokes != null ||

        _isEraserActive(buttons, kind);

    if (wasErasing) {
      if (_eraserPendingTouch && _eraserTouchDownPos != null) {
        // Single tap touch erase
        _eraserGestureInitialStrokes ??= List.from(_strokes);
        _handleEraser(_eraserTouchDownPos!);
        _eraserPendingTouch = false;
        _eraserTouchDownPos = null;
      }
      if (_eraserGestureDidModify && _eraserGestureInitialStrokes != null) {
        _recordSnapshot(_eraserGestureInitialStrokes!);
        _redoStack.clear();
        notifyListeners();
      }
      _eraserGestureInitialStrokes = null;
      _eraserGestureDidModify = false;
      return;
    }

    if (_activeTool == ToolType.text) {
      final tapPos = _textTouchDownPos;
      final dist = _textDragDistance;
      _textTouchDownPos = null;
      _textDragDistance = 0.0;
      _drawingPointerId = null;

      // Only act on stationary taps (not during drag, scroll, or cancelled pinch)
      if (tapPos != null && dist < 12.0) {
        if (activeTextBoxId != null) {
          final box = activeTextBox;
          if (box == null || !box.bounds.inflate(28.0).contains(tapPos)) {
            unfocusActiveTextBox();
          }
        }

        if (_selectedImageId != null) {
          final img = selectedImage;
          if (img != null) {
            final activeRect = Rect.fromLTRB(
              img.position.dx - 72.0,
              img.position.dy - 32.0,
              img.position.dx + img.width + 72.0,
              img.position.dy + img.height + 72.0,
            );
            if (!activeRect.contains(tapPos)) {
              selectImage(null);
            }
          } else {
            selectImage(null);
          }
        }

        // 1. Check if tapping an image across all pages
        final pageOrder = <int>[
          _activePageIndex,
          for (int i = _pages.length - 1; i >= 0; i--)
            if (i != _activePageIndex) i,
        ];
        NoteImage? hitImg;
        int? hitImgPageIndex;
        for (final p in pageOrder) {
          if (p < 0 || p >= _pages.length) continue;
          final yShift = (_activePageIndex - p) * AppConstants.pagePitch;
          final localTap = tapPos.translate(0.0, yShift);
          for (final img in _pages[p].images.reversed) {
            final isImgSelected = _selectedImageId == img.id;
            final bottomExtra = isImgSelected ? 72.0 : 16.0;
            final topExtra = isImgSelected ? 32.0 : 16.0;
            final horizontalExtra = isImgSelected ? 72.0 : 16.0;
            final imgHitRect = Rect.fromLTRB(
              img.position.dx - horizontalExtra,
              img.position.dy - topExtra,
              img.position.dx + img.width + horizontalExtra,
              img.position.dy + img.height + bottomExtra,
            );
            if (imgHitRect.contains(localTap)) {
              hitImg = img;
              hitImgPageIndex = p;
              break;
            }
          }
          if (hitImg != null) break;
        }
        if (hitImg != null && hitImgPageIndex != null) {
          _activePageIndex = hitImgPageIndex;
          selectImage(hitImg.id);
          return;
        }

        // 2. Check if tapping an existing text box
        NoteTextBox? hit;
        for (final box in _textBoxes.reversed) {
          if (box.bounds.inflate(28.0).contains(tapPos)) {
            hit = box;
            break;
          }
        }
        if (hit != null) {
          selectTextBox(hit.id);
        } else {
          addTextBox(tapPos);
        }
      }
      return;
    }

    if (_activeTool == ToolType.lasso) {
      if (_pointerDownOnToolbar) {
        _pointerDownOnToolbar = false;
        _lassoTouchDownPos = null;
        _lassoDragDistance = 0.0;
        return;
      }

      if (_lassoTransformDidModify && _lassoPreTransformAllStrokes != null) {
        _recordSnapshot(_lassoPreTransformAllStrokes!);
        _redoStack.clear();

        // Cross-page transfer if moving selection across page boundaries
        if (_activeLassoHandle == LassoHandle.move &&
            _selectionBounds != null &&
            _pages.length > 1) {
          final sourcePageIndex = _activePageIndex;
          final centerGlobalY = AppConstants.pageHeaderHeight +
              sourcePageIndex * AppConstants.pagePitch +
              _selectionBounds!.center.dy;
          final targetPageIndex = (centerGlobalY / AppConstants.pagePitch)
              .floor()
              .clamp(0, _pages.length - 1);

          if (targetPageIndex != sourcePageIndex) {
            final yShift =
                (sourcePageIndex - targetPageIndex) * AppConstants.pagePitch;
            final transferredStrokes = LassoService.translateStrokes(
              _selectedStrokes,
              Offset(0.0, yShift),
            );
            _selectionBounds = _selectionBounds!.shift(Offset(0.0, yShift));

            // Remove moved strokes from source page
            final selIndicesSet = _lassoSelectedIndices.toSet();
            final remainingSourceStrokes = <Stroke>[];
            for (int i = 0; i < _lassoPreTransformAllStrokes!.length; i++) {
              if (!selIndicesSet.contains(i)) {
                remainingSourceStrokes.add(_lassoPreTransformAllStrokes![i]);
              }
            }
            _pages[sourcePageIndex].strokes = remainingSourceStrokes;

            // Append transferred strokes to target page
            _pages[targetPageIndex].strokes = [
              ..._pages[targetPageIndex].strokes,
              ...transferredStrokes,
            ];

            _selectedStrokes = transferredStrokes;
            _activePageIndex = targetPageIndex;
          }
        }

        _lassoPreTransformAllStrokes = null;
        _lassoInitialSelectedStrokes = null;
        _lassoInitialBounds = null;
        _lassoTransformDidModify = false;
        _lassoRotationCenter = null;
        _lassoRotationStartAngle = null;
        _lassoSelectedIndices.clear();
        _activeLassoHandle = LassoHandle.none;
        notifyListeners();
        return;
      }

      // If user tapped a handle or clicked inside selection without dragging, keep selection
      if (_activeLassoHandle != LassoHandle.none) {
        _lassoPreTransformAllStrokes = null;
        _lassoInitialSelectedStrokes = null;
        _lassoInitialBounds = null;
        _lassoTransformDidModify = false;
        _lassoRotationCenter = null;
        _lassoRotationStartAngle = null;
        _lassoSelectedIndices.clear();
        _activeLassoHandle = LassoHandle.none;
        _lassoTouchDownPos = null;
        _lassoDragDistance = 0.0;
        notifyListeners();
        return;
      }

      _lassoPreTransformAllStrokes = null;
      _lassoInitialSelectedStrokes = null;
      _lassoInitialBounds = null;
      _lassoTransformDidModify = false;
      _lassoRotationCenter = null;
      _lassoRotationStartAngle = null;
      _lassoSelectedIndices.clear();
      _activeLassoHandle = LassoHandle.none;

      final points = lassoPointsNotifier.value;
      final isTap = _lassoDragDistance < 10.0 || points.length < 3;

      if (isTap && _lassoTouchDownPos != null) {
        // --- SINGLE TAP SELECTION MODE ---
        // Search across all pages (active page first, then reverse chronological order)
        final pageOrder = <int>[
          _activePageIndex,
          for (int i = _pages.length - 1; i >= 0; i--)
            if (i != _activePageIndex) i,
        ];

        // 1. Check if tapping an image
        NoteImage? foundImg;
        int? foundImgPageIndex;
        for (final p in pageOrder) {
          if (p < 0 || p >= _pages.length) continue;
          final yShift = (_activePageIndex - p) * AppConstants.pagePitch;
          final localTap = _lassoTouchDownPos!.translate(0.0, yShift);
          for (final img in _pages[p].images.reversed) {
            final isImgSelected = _selectedImageId == img.id;
            final bottomExtra = isImgSelected ? 72.0 : 16.0;
            final topExtra = isImgSelected ? 32.0 : 16.0;
            final horizontalExtra = isImgSelected ? 72.0 : 16.0;
            final imgHitRect = Rect.fromLTRB(
              img.position.dx - horizontalExtra,
              img.position.dy - topExtra,
              img.position.dx + img.width + horizontalExtra,
              img.position.dy + img.height + bottomExtra,
            );
            if (imgHitRect.contains(localTap)) {
              foundImg = img;
              foundImgPageIndex = p;
              break;
            }
          }
          if (foundImg != null) break;
        }

        if (foundImg != null && foundImgPageIndex != null) {
          deselect();
          _activePageIndex = foundImgPageIndex;
          selectImage(foundImg.id);
          _lassoTouchDownPos = null;
          _lassoDragDistance = 0.0;
          lassoPointsNotifier.value = [];
          notifyListeners();
          return;
        }

        // 2. Check if tapping a stroke
        Stroke? foundStroke;
        int? foundPageIndex;

        for (final p in pageOrder) {
          if (p < 0 || p >= _pages.length) continue;
          final yShift = (_activePageIndex - p) * AppConstants.pagePitch;
          final localTap = _lassoTouchDownPos!.translate(0.0, yShift);
          final stroke = LassoService.findTopmostStrokeAtPoint(
            _pages[p].strokes,
            localTap,
          );
          if (stroke != null) {
            foundStroke = stroke;
            foundPageIndex = p;
            break;
          }
        }

        if (foundStroke != null && foundPageIndex != null) {
          selectImage(null);
          _activePageIndex = foundPageIndex;
          _selectedStrokes = [foundStroke];
          _selectionBounds = LassoService.computeSelectionBounds([foundStroke]);
          _selectionRotation = 0.0;
        } else {
          deselect();
          selectImage(null);
        }
      }
 else if (points.length >= 3) {
        // --- FREEFORM LASSO LOOP SELECTION ---
        // Search across all pages and margins
        final hitsPerPage = <int, List<Stroke>>{};
        for (int p = 0; p < _pages.length; p++) {
          final yShift = (_activePageIndex - p) * AppConstants.pagePitch;
          final polygonOnPageP =
              points.map((pt) => pt.translate(0.0, yShift)).toList();
          final hits =
              LassoService.findSelectedStrokes(_pages[p].strokes, polygonOnPageP);
          if (hits.isNotEmpty) {
            hitsPerPage[p] = hits;
          }
        }

        if (hitsPerPage.isEmpty) {
          deselect();
        } else if (hitsPerPage.length == 1) {
          final p = hitsPerPage.keys.first;
          final selected = hitsPerPage[p]!;
          _activePageIndex = p;
          _selectedStrokes = selected;
          _selectionBounds = LassoService.computeSelectionBounds(selected);
          _selectionRotation = 0.0;
        } else {
          // Multi-page selection: unify all selected strokes into target page
          final targetP = hitsPerPage.containsKey(_activePageIndex)
              ? _activePageIndex
              : hitsPerPage.keys.first;

          final allUnified = <Stroke>[];
          for (final entry in hitsPerPage.entries) {
            final p = entry.key;
            final strokesOnP = entry.value;
            if (p == targetP) {
              allUnified.addAll(strokesOnP);
            } else {
              // Shift strokes from page p into targetP coordinate space
              final yShift = (p - targetP) * AppConstants.pagePitch;
              final transferred = LassoService.translateStrokes(
                strokesOnP,
                Offset(0.0, yShift),
              );
              allUnified.addAll(transferred);

              // Remove transferred strokes from page p
              final toRemove = strokesOnP.toSet();
              _pages[p].strokes = _pages[p].strokes
                  .where((s) => !toRemove.contains(s))
                  .toList();
              // Add to targetP
              _pages[targetP].strokes = [
                ..._pages[targetP].strokes,
                ...transferred,
              ];
            }
          }
          _activePageIndex = targetP;
          _selectedStrokes = allUnified;
          _selectionBounds = LassoService.computeSelectionBounds(allUnified);
          _selectionRotation = 0.0;
        }
      } else {
        deselect();
      }

      lassoPointsNotifier.value = [];
      _lassoTouchDownPos = null;
      _lassoDragDistance = 0.0;
      notifyListeners();
      return;
    }

    if (!_isDrawing) return;

    final rawPoints = currentStrokeNotifier.value;
    if (rawPoints.isNotEmpty) {
      final lastPoint = StrokePoint(
        localPosition.dx,
        localPosition.dy,
        pressure: pressure > 0.0 ? pressure : 0.5,
      );
      final finalPoints = [...rawPoints, lastPoint];
      final compressed = Stroke.compressPoints(finalPoints);

      Color strokeColor = activeColor;
      if (_activeTool == ToolType.highlighter && strokeColor.a >= 1.0) {
        strokeColor = strokeColor.withValues(alpha: 0.38);
      }

      _recordHistory();
      _strokes = [
        ..._strokes,
        Stroke(
          points: compressed,
          color: strokeColor,
          strokeWidth: strokeWidth,
          toolType: _activeTool,
        ),
      ];
      _redoStack.clear();
    }

    _isDrawing = false;
    currentStrokeNotifier.value = [];
    notifyListeners();
  }

  void onPointerCancel({int pointer = 0}) {
    _activePointers.remove(pointer);
    eraserPointerNotifier.value = null;
    if (_eraserGestureDidModify && _eraserGestureInitialStrokes != null) {
      _recordSnapshot(_eraserGestureInitialStrokes!);
      _redoStack.clear();
    }
    _eraserGestureInitialStrokes = null;
    _eraserGestureDidModify = false;

    if (_lassoTransformDidModify && _lassoPreTransformAllStrokes != null) {
      _recordSnapshot(_lassoPreTransformAllStrokes!);
      _redoStack.clear();
    }
    _lassoPreTransformAllStrokes = null;
    _lassoInitialSelectedStrokes = null;
    _lassoInitialBounds = null;
    _lassoTransformDidModify = false;
    _activeLassoHandle = LassoHandle.none;
    _lassoTouchDownPos = null;
    _lassoDragDistance = 0.0;
    lassoPointsNotifier.value = [];

    if (_activePointers.isEmpty) {
      _isMultiTouch = false;
    }
    if (_drawingPointerId == pointer) {
      _drawingPointerId = null;
      _eraserPendingTouch = false;
      _eraserTouchDownPos = null;
      _textTouchDownPos = null;
      _textDragDistance = 0.0;
      if (_isDrawing) {
        _isDrawing = false;
        currentStrokeNotifier.value = [];
      }
    }
  }

  void _handleEraser(Offset pointer) {
    _eraserGestureInitialStrokes ??= List.from(_strokes);

    if (_activeTool == ToolType.areaEraser) {
      // Area / Precision Eraser: geometric slicing of strokes
      bool modified = false;
      final List<Stroke> newStrokes = [];

      for (final stroke in _strokes) {
        final fragments =
            EraserService.sliceStroke(stroke, pointer, _eraserRadius);
        final isUnchanged =
            fragments.length == 1 && identical(fragments.first, stroke);

        if (!isUnchanged) {
          modified = true;
          newStrokes.addAll(fragments);
        } else {
          newStrokes.add(stroke);
        }
      }

      if (modified) {
        _eraserGestureDidModify = true;
        _strokes = newStrokes;
        notifyListeners();
      }
    } else {
      // Stroke Eraser: deletes entire stroke upon intersection
      bool strokeRemoved = false;
      final List<Stroke> remaining = [];

      for (final stroke in _strokes) {
        if (EraserService.hitTestStroke(stroke, pointer, _eraserRadius)) {
          strokeRemoved = true;
        } else {
          remaining.add(stroke);
        }
      }

      if (strokeRemoved) {
        _eraserGestureDidModify = true;
        _strokes = remaining;
        notifyListeners();
      }
    }
  }

  void undo() {
    // If an in-progress lasso transform modified strokes, commit snapshot first
    if (_lassoTransformDidModify && _lassoPreTransformAllStrokes != null) {
      _recordSnapshot(_lassoPreTransformAllStrokes!);
      _redoStack.clear();
      _lassoPreTransformAllStrokes = null;
      _lassoInitialSelectedStrokes = null;
      _lassoInitialBounds = null;
      _lassoTransformDidModify = false;
      _activeLassoHandle = LassoHandle.none;
    }
    deselect();

    // If an in-progress eraser gesture modified strokes before pointer-up, commit snapshot first
    if (_eraserGestureDidModify && _eraserGestureInitialStrokes != null) {
      _recordSnapshot(_eraserGestureInitialStrokes!);
      _redoStack.clear();
      _eraserGestureInitialStrokes = null;
      _eraserGestureDidModify = false;
    }
    if (_undoStack.isEmpty) return;
    _redoStack.add(CanvasHistorySnapshot(
      pages: _pages.map((p) => p.clone()).toList(),
      activePageIndex: _activePageIndex,
    ));
    _contentVersion++;
    final prev = _undoStack.removeLast();
    _pages = prev.pages.map((p) => p.clone()).toList();
    _activePageIndex = prev.activePageIndex.clamp(0, _pages.length - 1);
    _activeTextBoxId = null;
    _activeRichTextController = null;
    notifyListeners();
  }

  void redo() {
    deselect();
    if (_redoStack.isEmpty) return;
    _undoStack.add(CanvasHistorySnapshot(
      pages: _pages.map((p) => p.clone()).toList(),
      activePageIndex: _activePageIndex,
    ));
    _contentVersion++;
    final next = _redoStack.removeLast();
    _pages = next.pages.map((p) => p.clone()).toList();
    _activePageIndex = next.activePageIndex.clamp(0, _pages.length - 1);
    _activeTextBoxId = null;
    _activeRichTextController = null;
    notifyListeners();
  }

  void clear() {
    deselect();
    if (activePage.strokes.isEmpty && activePage.textBoxes.isEmpty) return;
    _recordHistory();
    activePage.strokes = [];
    activePage.textBoxes = [];
    _activeTextBoxId = null;
    _activeRichTextController = null;
    _redoStack.clear();
    notifyListeners();
  }

  void _recordSnapshot(
    List<Stroke> strokeSnapshot, {
    List<NoteTextBox>? textBoxSnapshot,
  }) {
    final clonedPages = _pages.map((p) => p.clone()).toList();
    if (_activePageIndex < clonedPages.length) {
      clonedPages[_activePageIndex].strokes = List.from(strokeSnapshot);
      if (textBoxSnapshot != null) {
        clonedPages[_activePageIndex].textBoxes =
            textBoxSnapshot.map((b) => b.copyWith()).toList();
      }
    }
    _contentVersion++;
    _undoStack.add(CanvasHistorySnapshot(
      pages: clonedPages,
      activePageIndex: _activePageIndex,
    ));
    if (_undoStack.length > 50) {
      _undoStack.removeAt(0);
    }
  }

  void _recordHistory() {
    _contentVersion++;
    _undoStack.add(CanvasHistorySnapshot(
      pages: _pages.map((p) => p.clone()).toList(),
      activePageIndex: _activePageIndex,
    ));
    if (_undoStack.length > 50) {
      _undoStack.removeAt(0);
    }
  }

  @override
  void dispose() {
    _activeRichTextController?.removeListener(_onRichTextControllerChanged);
    currentStrokeNotifier.dispose();
    eraserPointerNotifier.dispose();
    lassoPointsNotifier.dispose();
    super.dispose();
  }
}
