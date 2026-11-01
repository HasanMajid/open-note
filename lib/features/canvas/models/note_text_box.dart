import 'package:flutter/material.dart';
import 'package:open_note/features/canvas/models/rich_text_span.dart';

/// An independent, movable, and resizable rich text block container on the canvas.
class NoteTextBox {
  final String id;
  Offset position;
  double width;
  double? height;
  String text;
  List<RichTextSpan> spans;
  TextDirection? textDirection;
  double? defaultFontSize;
  Map<HeadingLevel, double>? headingDefaultFontSizes;

  NoteTextBox({
    required this.id,
    required this.position,
    this.width = 300.0,
    this.height,
    this.text = '',
    List<RichTextSpan>? spans,
    this.textDirection,
    this.defaultFontSize,
    this.headingDefaultFontSizes,
  }) : spans = spans ?? [];

  /// Minimum width allowed when resizing
  static const double minWidth = 120.0;

  /// Detects whether [text] contains Right-to-Left characters (Arabic, Hebrew, Persian, Urdu, etc.)
  static bool isRtlText(String text) {
    if (text.isEmpty) return false;
    final rtlRegex = RegExp(
      r'[\u0590-\u05FF\u0600-\u06FF\u0700-\u074F\u0750-\u077F\u0780-\u07BF\u08A0-\u08FF\uFB1D-\uFB4F\uFB50-\uFDFF\uFE70-\uFEFF]',
    );
    return rtlRegex.hasMatch(text);
  }

  /// The active text direction, falling back to script detection if unset.
  TextDirection get effectiveTextDirection {
    if (textDirection != null) return textDirection!;
    return isRtlText(text) ? TextDirection.rtl : TextDirection.ltr;
  }

  /// Approximate visual bounding box of the text container.
  Rect get bounds => Rect.fromLTWH(
        position.dx,
        position.dy,
        width,
        height ?? 44.0,
      );

  NoteTextBox copyWith({
    String? id,
    Offset? position,
    double? width,
    double? height,
    String? text,
    List<RichTextSpan>? spans,
    TextDirection? textDirection,
    double? defaultFontSize,
    Map<HeadingLevel, double>? headingDefaultFontSizes,
  }) {
    return NoteTextBox(
      id: id ?? this.id,
      position: position ?? this.position,
      width: width ?? this.width,
      height: height ?? this.height,
      text: text ?? this.text,
      spans: spans != null
          ? List.from(spans)
          : this.spans.map((s) => s.copyWith()).toList(),
      textDirection: textDirection ?? this.textDirection,
      defaultFontSize: defaultFontSize ?? this.defaultFontSize,
      headingDefaultFontSizes: headingDefaultFontSizes != null
          ? Map.from(headingDefaultFontSizes)
          : (this.headingDefaultFontSizes != null
              ? Map.from(this.headingDefaultFontSizes!)
              : null),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'x': position.dx,
      'y': position.dy,
      'width': width,
      if (height != null) 'height': height,
      'text': text,
      'spans': spans.map((s) => s.toJson()).toList(),
      if (textDirection != null) 'textDirection': textDirection!.name,
      if (defaultFontSize != null) 'defaultFontSize': defaultFontSize,
      if (headingDefaultFontSizes != null)
        'headingDefaultFontSizes': headingDefaultFontSizes!.map(
          (k, v) => MapEntry(k.name, v),
        ),
    };
  }

  factory NoteTextBox.fromJson(Map<String, dynamic> json) {
    final rawSpans = (json['spans'] as List<dynamic>?) ?? [];
    final dirStr = json['textDirection'] as String?;
    final rawHeadingSizes =
        json['headingDefaultFontSizes'] as Map<String, dynamic>?;
    final headingDefaultFontSizes = rawHeadingSizes?.map(
      (k, v) => MapEntry(
        HeadingLevel.values.firstWhere(
          (h) => h.name == k,
          orElse: () => HeadingLevel.none,
        ),
        (v as num).toDouble(),
      ),
    );

    return NoteTextBox(
      id: json['id'] as String? ?? 'box_${DateTime.now().millisecondsSinceEpoch}',
      position: Offset(
        (json['x'] as num?)?.toDouble() ?? 0.0,
        (json['y'] as num?)?.toDouble() ?? 0.0,
      ),
      width: (json['width'] as num?)?.toDouble() ?? 300.0,
      height: (json['height'] as num?)?.toDouble(),
      text: json['text'] as String? ?? '',
      spans: rawSpans
          .map((s) => RichTextSpan.fromJson(s as Map<String, dynamic>))
          .toList(),
      textDirection: dirStr == 'rtl'
          ? TextDirection.rtl
          : (dirStr == 'ltr' ? TextDirection.ltr : null),
      defaultFontSize: (json['defaultFontSize'] as num?)?.toDouble(),
      headingDefaultFontSizes: headingDefaultFontSizes,
    );
  }
}
