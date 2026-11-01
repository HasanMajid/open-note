import 'dart:math';
import 'package:flutter/material.dart';
import 'package:open_note/features/canvas/models/rich_text_span.dart';

/// A native [TextEditingController] that manages non-destructive attributed formatting spans.
///
/// Features:
/// - Elementary boundary slicing algorithm producing disjoint styled [TextSpan]s.
/// - Automatic span adjustment on typing, pasting, and backspacing.
/// - Rich formatting toggles: Bold, Italic, Underline, Strikethrough, Headings, and Colors.
/// - Active typing style persistence for collapsed cursor typing without modifying existing unhighlighted text.
class RichTextEditingController extends TextEditingController {
  List<RichTextSpan> _spans = [];
  String _previousText = '';

  // Active styling for newly typed characters when cursor is collapsed
  HeadingLevel _typingHeading = HeadingLevel.none;
  bool _typingBold = false;
  bool _typingItalic = false;
  bool _typingUnderline = false;
  bool _typingStrikethrough = false;
  double? _typingFontSize;
  Color? _typingColor;
  Color? _typingHighlightColor;
  final double _defaultFontSize;
  final Map<HeadingLevel, double> _headingDefaultFontSizes;

  RichTextEditingController({
    super.text,
    List<RichTextSpan>? spans,
    HeadingLevel defaultHeading = HeadingLevel.none,
    bool defaultBold = false,
    bool defaultItalic = false,
    bool defaultUnderline = false,
    bool defaultStrikethrough = false,
    double? defaultFontSize,
    Map<HeadingLevel, double>? headingDefaultFontSizes,
    Color? defaultColor,
    Color? defaultHighlight,
  }) : _defaultFontSize = defaultFontSize ?? 15.0,
       _headingDefaultFontSizes = {
         HeadingLevel.none: defaultFontSize ?? 15.0,
         HeadingLevel.h1: headingDefaultFontSizes?[HeadingLevel.h1] ?? 26.0,
         HeadingLevel.h2: headingDefaultFontSizes?[HeadingLevel.h2] ?? 20.0,
         HeadingLevel.h3: headingDefaultFontSizes?[HeadingLevel.h3] ?? 17.0,
         if (headingDefaultFontSizes != null) ...headingDefaultFontSizes,
       } {
    _spans = spans != null ? List.from(spans) : [];
    _previousText = text;
    _typingHeading = defaultHeading;
    _typingBold = defaultBold;
    _typingItalic = defaultItalic;
    _typingUnderline = defaultUnderline;
    _typingStrikethrough = defaultStrikethrough;
    _typingFontSize = null;
    _typingColor = defaultColor;
    _typingHighlightColor = defaultHighlight;
  }

  double get defaultFontSize =>
      _headingDefaultFontSizes[HeadingLevel.none] ?? _defaultFontSize;

  double defaultFontSizeForHeading(HeadingLevel heading) =>
      _headingDefaultFontSizes[heading] ?? heading.defaultFontSize;

  void setDefaultFontSizeForHeading(HeadingLevel heading, double size) {
    _headingDefaultFontSizes[heading] = size;
    notifyListeners();
  }

  Map<HeadingLevel, double> get headingDefaultFontSizes =>
      Map.unmodifiable(_headingDefaultFontSizes);

  List<RichTextSpan> get spans => List.unmodifiable(_spans);

  bool _isDarkMode = false;
  bool get isDarkMode => _isDarkMode;
  set isDarkMode(bool val) {
    if (_isDarkMode != val) {
      _isDarkMode = val;
      notifyListeners();
    }
  }

  set spans(List<RichTextSpan> newSpans) {
    _spans = List.from(newSpans);
    notifyListeners();
  }

  TextSelection _lastSelection = const TextSelection.collapsed(offset: -1);

  @override
  set value(TextEditingValue newValue) {
    final oldSelection = selection;
    final newSelection = newValue.selection;
    if (newSelection.isValid && newSelection.baseOffset >= 0) {
      _lastSelection = newSelection;
    }
    final oldText = _previousText;
    final newText = newValue.text;

    if (oldText != newText) {
      _adjustSpansOnTextChange(oldText, newText);
      _previousText = newText;
    } else if (newSelection != oldSelection) {
      _updateTypingStyleFromCursor(newSelection);
    }

    super.value = newValue;
  }

  void _updateTypingStyleFromCursor(TextSelection sel) {
    if (!sel.isCollapsed || text.isEmpty) return;
    final cursor = sel.baseOffset.clamp(0, text.length);
    final targetIndex = cursor > 0 ? cursor - 1 : 0;
    RichTextSpan? hitSpan;
    for (final s in _spans) {
      if (s.contains(targetIndex)) {
        hitSpan = s;
        break;
      }
    }
    if (hitSpan != null) {
      _typingHeading = hitSpan.heading;
      _typingBold = hitSpan.bold;
      _typingItalic = hitSpan.italic;
      _typingUnderline = hitSpan.underline;
      _typingStrikethrough = hitSpan.strikethrough;
      _typingFontSize = hitSpan.fontSize;
      _typingColor = hitSpan.color;
      _typingHighlightColor = hitSpan.highlightColor;
    } else {
      _typingHeading = HeadingLevel.none;
      _typingBold = false;
      _typingItalic = false;
      _typingUnderline = false;
      _typingStrikethrough = false;
      _typingFontSize = null;
      _typingColor = null;
      _typingHighlightColor = null;
    }
    notifyListeners();
  }

  /// Automatically shifts, resizes, and assigns styles when text is inserted or deleted.
  void _adjustSpansOnTextChange(String oldText, String newText) {
    if (_spans.isEmpty && !_typingHasAttributes) return;

    final oldLen = oldText.length;
    final newLen = newText.length;

    // Detect common prefix
    int prefixLen = 0;
    while (prefixLen < oldLen &&
        prefixLen < newLen &&
        oldText.codeUnitAt(prefixLen) == newText.codeUnitAt(prefixLen)) {
      prefixLen++;
    }

    // Detect common suffix (bounded by prefix)
    int suffixLen = 0;
    while (suffixLen < (oldLen - prefixLen) &&
        suffixLen < (newLen - prefixLen) &&
        oldText.codeUnitAt(oldLen - 1 - suffixLen) ==
            newText.codeUnitAt(newLen - 1 - suffixLen)) {
      suffixLen++;
    }

    final deletedStart = prefixLen;
    final deletedEnd = oldLen - suffixLen;
    final deletedCount = deletedEnd - deletedStart;
    final insertedCount = newLen - prefixLen - suffixLen;

    final List<RichTextSpan> updatedSpans = [];

    for (final span in _spans) {
      int start = span.start;
      int end = span.end;

      // 1. Text deletion handling
      if (deletedCount > 0) {
        if (start >= deletedEnd) {
          start -= deletedCount;
          end -= deletedCount;
        } else if (end <= deletedStart) {
          // Unchanged
        } else {
          if (start > deletedStart) start = deletedStart;
          final overlap =
              min<int>(span.end, deletedEnd) - max<int>(span.start, deletedStart);
          end -= overlap;
        }
      }

      // 2. Text insertion handling
      if (insertedCount > 0) {
        final insertPos = deletedStart;
        if (start > insertPos) {
          // Span is after insertion point -> shift forward
          start += insertedCount;
          end += insertedCount;
        } else if (start <= insertPos && end > insertPos) {
          // Insertion point is inside span
          if (start < insertPos || _typingMatchesSpan(span)) {
            end += insertedCount;
          } else {
            // At start boundary and typing differs -> shift forward
            start += insertedCount;
            end += insertedCount;
          }
        } else if (end == insertPos) {
          // Insertion point is right at the end of the span
          if (_typingMatchesSpan(span)) {
            end += insertedCount;
          }
        }
      }

      start = start.clamp(0, newLen);
      end = end.clamp(0, newLen);
      if (start < end) {
        updatedSpans.add(span.copyWith(start: start, end: end));
      }
    }

    // 3. If text was inserted and active typing style has attributes, create or expand span
    if (insertedCount > 0 && _typingHasAttributes) {
      final insertStart = deletedStart;
      final insertEnd = deletedStart + insertedCount;
      final alreadyCovered = updatedSpans.any(
        (s) =>
            s.start <= insertStart &&
            s.end >= insertEnd &&
            _typingMatchesSpan(s),
      );

      if (!alreadyCovered) {
        updatedSpans.add(RichTextSpan(
          start: insertStart,
          end: insertEnd,
          bold: _typingBold,
          italic: _typingItalic,
          underline: _typingUnderline,
          strikethrough: _typingStrikethrough,
          fontSize: _typingFontSize,
          color: _typingColor,
          highlightColor: _typingHighlightColor,
          heading: _typingHeading,
        ));
      }
    }

    _spans = _mergeAdjacentSpans(updatedSpans);
  }

  bool _typingMatchesSpan(RichTextSpan span) {
    return span.heading == _typingHeading &&
        span.bold == _typingBold &&
        span.italic == _typingItalic &&
        span.underline == _typingUnderline &&
        span.strikethrough == _typingStrikethrough &&
        span.fontSize == _typingFontSize &&
        span.color == _typingColor &&
        span.highlightColor == _typingHighlightColor;
  }

  bool get _typingHasAttributes =>
      _typingHeading != HeadingLevel.none ||
      _typingBold ||
      _typingItalic ||
      _typingUnderline ||
      _typingStrikethrough ||
      _typingFontSize != null ||
      _typingColor != null ||
      _typingHighlightColor != null;

  List<RichTextSpan> _mergeAdjacentSpans(List<RichTextSpan> input) {
    if (input.length <= 1) return input;
    final sorted = List<RichTextSpan>.from(input)
      ..sort((a, b) => a.start.compareTo(b.start));

    final List<RichTextSpan> merged = [];
    for (final span in sorted) {
      if (merged.isEmpty) {
        merged.add(span);
        continue;
      }
      final last = merged.last;
      if (last.end == span.start && _spansMatch(last, span)) {
        merged[merged.length - 1] = last.copyWith(end: span.end);
      } else {
        merged.add(span);
      }
    }
    return merged;
  }

  bool _spansMatch(RichTextSpan a, RichTextSpan b) {
    return a.heading == b.heading &&
        a.bold == b.bold &&
        a.italic == b.italic &&
        a.underline == b.underline &&
        a.strikethrough == b.strikethrough &&
        a.fontSize == b.fontSize &&
        a.color == b.color &&
        a.highlightColor == b.highlightColor;
  }

  // ===========================================================================
  // Boundary Slicing & Rendering Algorithm
  // ===========================================================================

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (text.isEmpty) {
      return TextSpan(style: style, text: '');
    }

    if (_spans.isEmpty) {
      return TextSpan(style: style, text: text);
    }

    // 1. Collect all boundary points: {0, text.length} U {start, end for each span}
    final Set<int> boundarySet = {0, text.length};
    for (final s in _spans) {
      if (s.start >= 0 && s.start <= text.length) boundarySet.add(s.start);
      if (s.end >= 0 && s.end <= text.length) boundarySet.add(s.end);
    }

    final List<int> boundaries = boundarySet.toList()..sort();
    final List<TextSpan> children = [];

    // 2. Iterate each elementary disjoint slice [b_i, b_{i+1}]
    for (int i = 0; i < boundaries.length - 1; i++) {
      final segStart = boundaries[i];
      final segEnd = boundaries[i + 1];
      if (segStart >= segEnd) continue;

      final segText = text.substring(segStart, segEnd);

      bool isBold = false;
      bool isItalic = false;
      bool isUnderline = false;
      bool isStrikethrough = false;
      Color? segColor;
      Color? segHighlight;
      HeadingLevel segHeading = HeadingLevel.none;
      double? segFontSize;

      for (final s in _spans) {
        if (s.start <= segStart && s.end >= segEnd) {
          if (s.bold) isBold = true;
          if (s.italic) isItalic = true;
          if (s.underline) isUnderline = true;
          if (s.strikethrough) isStrikethrough = true;
          if (s.color != null) segColor = s.color;
          if (s.highlightColor != null) segHighlight = s.highlightColor;
          if (s.heading != HeadingLevel.none) segHeading = s.heading;
          if (s.fontSize != null) segFontSize = s.fontSize;
        }
      }

      final sliceSpan = RichTextSpan(
        start: segStart,
        end: segEnd,
        bold: isBold,
        italic: isItalic,
        underline: isUnderline,
        strikethrough: isStrikethrough,
        color: segColor,
        highlightColor: segHighlight,
        heading: segHeading,
        fontSize: segFontSize ?? defaultFontSizeForHeading(segHeading),
      );

      children.add(TextSpan(
        text: segText,
        style: sliceSpan.toTextStyle(baseStyle: style, isDarkMode: _isDarkMode),
      ));
    }

    return TextSpan(children: children);
  }

  // ===========================================================================
  // Rich Text Formatting Action API
  // ===========================================================================

  /// Returns the active selection or the last remembered non-collapsed selection.
  TextSelection get effectiveSelection {
    if (selection.isValid && selection.baseOffset >= 0) {
      return selection;
    }
    if (_lastSelection.isValid && _lastSelection.baseOffset >= 0) {
      return _lastSelection;
    }
    return selection;
  }

  bool get isSelectionBold =>
      effectiveSelection.isCollapsed
          ? _typingBold
          : _checkSelectionAttribute((s) => s.bold);

  bool get isSelectionItalic =>
      effectiveSelection.isCollapsed
          ? _typingItalic
          : _checkSelectionAttribute((s) => s.italic);

  bool get isSelectionUnderline =>
      effectiveSelection.isCollapsed
          ? _typingUnderline
          : _checkSelectionAttribute((s) => s.underline);

  bool get isSelectionStrikethrough =>
      effectiveSelection.isCollapsed
          ? _typingStrikethrough
          : _checkSelectionAttribute((s) => s.strikethrough);

  Color? get currentTextColor {
    final sel = effectiveSelection;
    if (sel.isCollapsed) return _typingColor;
    for (final s in _spans) {
      if (s.overlaps(sel.start, sel.end) && s.color != null) return s.color;
    }
    return null;
  }

  Color? get currentHighlightColor {
    final sel = effectiveSelection;
    if (sel.isCollapsed) return _typingHighlightColor;
    for (final s in _spans) {
      if (s.overlaps(sel.start, sel.end) && s.highlightColor != null) {
        return s.highlightColor;
      }
    }
    return null;
  }

  HeadingLevel get currentHeading {
    final sel = effectiveSelection;
    if (sel.isCollapsed) return _typingHeading;
    for (final s in _spans) {
      if (s.overlaps(sel.start, sel.end) && s.heading != HeadingLevel.none) {
        return s.heading;
      }
    }
    return HeadingLevel.none;
  }

  double get activeFontSize {
    final sel = effectiveSelection;
    if (sel.isCollapsed) {
      if (_typingFontSize != null) return _typingFontSize!;
      return defaultFontSizeForHeading(_typingHeading);
    }
    for (final s in _spans) {
      if (s.overlaps(sel.start, sel.end)) {
        if (s.fontSize != null) return s.fontSize!;
        return defaultFontSizeForHeading(s.heading);
      }
    }
    return _typingFontSize ?? defaultFontSizeForHeading(_typingHeading);
  }

  bool _checkSelectionAttribute(bool Function(RichTextSpan) check) {
    final sel = effectiveSelection;
    if (sel.isCollapsed) return false;
    final relevant = _spans.where(
      (s) => s.overlaps(sel.start, sel.end),
    );
    return relevant.isNotEmpty && relevant.every(check);
  }

  void toggleBold() {
    final sel = effectiveSelection;
    if (sel.isCollapsed || sel.start >= sel.end) {
      _typingBold = !_typingBold;
      notifyListeners();
      return;
    }
    final makeBold = !isSelectionBold;
    _typingBold = makeBold;
    _applyAttribute(
      sel.start,
      sel.end,
      (s) => s.copyWith(bold: makeBold),
      addIfMissing: makeBold
          ? (start, end) => RichTextSpan(start: start, end: end, bold: true)
          : null,
    );
  }

  void toggleItalic() {
    final sel = effectiveSelection;
    if (sel.isCollapsed || sel.start >= sel.end) {
      _typingItalic = !_typingItalic;
      notifyListeners();
      return;
    }
    final makeItalic = !isSelectionItalic;
    _typingItalic = makeItalic;
    _applyAttribute(
      sel.start,
      sel.end,
      (s) => s.copyWith(italic: makeItalic),
      addIfMissing: makeItalic
          ? (start, end) => RichTextSpan(start: start, end: end, italic: true)
          : null,
    );
  }

  void toggleUnderline() {
    final sel = effectiveSelection;
    if (sel.isCollapsed || sel.start >= sel.end) {
      _typingUnderline = !_typingUnderline;
      notifyListeners();
      return;
    }
    final makeUnderline = !isSelectionUnderline;
    _typingUnderline = makeUnderline;
    _applyAttribute(
      sel.start,
      sel.end,
      (s) => s.copyWith(underline: makeUnderline),
      addIfMissing: makeUnderline
          ? (start, end) =>
              RichTextSpan(start: start, end: end, underline: true)
          : null,
    );
  }

  void toggleStrikethrough() {
    final sel = effectiveSelection;
    if (sel.isCollapsed || sel.start >= sel.end) {
      _typingStrikethrough = !_typingStrikethrough;
      notifyListeners();
      return;
    }
    final makeStrikethrough = !isSelectionStrikethrough;
    _typingStrikethrough = makeStrikethrough;
    _applyAttribute(
      sel.start,
      sel.end,
      (s) => s.copyWith(strikethrough: makeStrikethrough),
      addIfMissing: makeStrikethrough
          ? (start, end) =>
              RichTextSpan(start: start, end: end, strikethrough: true)
          : null,
    );
  }

  void setHeading(HeadingLevel level) {
    final sel = effectiveSelection;
    _typingHeading = level;
    _typingFontSize = null;
    if (!sel.isCollapsed && sel.start < sel.end) {
      _applyHeadingRange(sel.start, sel.end, level);
    }
    notifyListeners();
  }

  void _applyHeadingRange(int start, int end, HeadingLevel level) {
    _applyAttribute(
      start,
      end,
      (s) => s.copyWith(heading: level, clearFontSize: true),
      addIfMissing: level != HeadingLevel.none
          ? (s, e) => RichTextSpan(start: s, end: e, heading: level)
          : null,
    );
  }

  void setTextColor(Color color) {
    final sel = effectiveSelection;
    _typingColor = color;
    if (!sel.isCollapsed && sel.start < sel.end) {
      _applyAttribute(
        sel.start,
        sel.end,
        (s) => s.copyWith(color: color),
        addIfMissing: (s, e) => RichTextSpan(start: s, end: e, color: color),
      );
    }
    notifyListeners();
  }

  void setTextHighlight(Color? color) {
    final sel = effectiveSelection;
    _typingHighlightColor = color;
    if (!sel.isCollapsed && sel.start < sel.end) {
      _applyAttribute(
        sel.start,
        sel.end,
        (s) => s.copyWith(highlightColor: color),
        addIfMissing: color != null
            ? (s, e) => RichTextSpan(start: s, end: e, highlightColor: color)
            : null,
      );
    }
    notifyListeners();
  }

  void setFontSize(double size) {
    final sel = effectiveSelection;
    _typingFontSize = size;
    if (!sel.isCollapsed && sel.start < sel.end) {
      _applyAttribute(
        sel.start,
        sel.end,
        (s) => s.copyWith(fontSize: size),
        addIfMissing: (s, e) => RichTextSpan(start: s, end: e, fontSize: size),
      );
    }
    notifyListeners();
  }

  /// Slices existing spans along [start, end] and modifies covered portions with [modifier],
  /// while also inserting [addIfMissing] for any gaps in [start, end] not covered by existing spans.
  void _applyAttribute(
    int start,
    int end,
    RichTextSpan Function(RichTextSpan) modifier, {
    RichTextSpan Function(int start, int end)? addIfMissing,
  }) {
    if (start >= end) return;

    final List<RichTextSpan> result = [];
    final List<RichTextSpan> overlapping = [];

    for (final s in _spans) {
      if (!s.overlaps(start, end)) {
        result.add(s);
      } else {
        overlapping.add(s);
      }
    }

    overlapping.sort((a, b) => a.start.compareTo(b.start));

    int currentPos = start;

    for (final s in overlapping) {
      if (s.start < start) {
        result.add(s.copyWith(end: start));
      }

      final gapStart = currentPos;
      final gapEnd = max(start, s.start);
      if (gapStart < gapEnd && addIfMissing != null) {
        result.add(addIfMissing(gapStart, gapEnd));
      }

      final overlapStart = max(s.start, start);
      final overlapEnd = min(s.end, end);
      if (overlapStart < overlapEnd) {
        final modified =
            modifier(s.copyWith(start: overlapStart, end: overlapEnd));
        result.add(modified);
      }

      if (s.end > end) {
        result.add(s.copyWith(start: end));
      }

      currentPos = max(currentPos, overlapEnd);
    }

    if (currentPos < end && addIfMissing != null) {
      result.add(addIfMissing(currentPos, end));
    }

    _spans = _mergeAdjacentSpans(result);
    notifyListeners();
  }
}
