import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart' as material;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:open_note/core/constants/app_constants.dart';
import 'package:open_note/core/theme/app_colors.dart';
import 'package:open_note/features/canvas/models/note_image.dart';
import 'package:open_note/features/canvas/models/note_text_box.dart';
import 'package:open_note/features/canvas/models/rich_text_span.dart';
import 'package:open_note/features/canvas/models/stroke.dart';
import 'package:open_note/features/canvas/models/stroke_point.dart';
import 'package:open_note/features/canvas/models/tool_type.dart';
import 'package:open_note/features/canvas/presentation/painters/page_background_painter.dart';
import 'package:open_note/features/notebook/models/note_document.dart';
import 'package:open_note/features/notebook/models/note_page.dart';

/// Export modes defining how page and pasteboard bounds are framed in the generated PDF.
enum PdfExportMode {
  /// Standard 1:1 scale matching the note page bounds (600 x 850).
  /// Content outside the inbound page boundary is clipped or remains off-page.
  pageBounds,

  /// Infinite canvas mode: computes the enclosing bounding box of all content
  /// (inking strokes, text boxes, images, pasteboard notes) and scales it down
  /// proportionally to fit comfortably on the PDF page so nothing is cut off.
  shrinkToFit,
}

/// Service responsible for rendering and exporting OpenNote documents to PDF files.
class PdfExportService {
  PdfExportService._();

  /// Default PDF page format matching OpenNote standard canvas size (600 x 850 points, 0 margin).
  static const PdfPageFormat defaultPageFormat = PdfPageFormat(
    600.0,
    850.0,
    marginAll: 0,
  );

  static (pw.Font, pw.Font, pw.Font, pw.Font)? _cachedFonts;

  static Future<(pw.Font regular, pw.Font bold, pw.Font italic, pw.Font boldItalic)>
      _getFonts() async {
    if (_cachedFonts != null) return _cachedFonts!;
    try {
      final regular = await PdfGoogleFonts.robotoRegular().timeout(
        const Duration(seconds: 1),
      );
      final bold = await PdfGoogleFonts.robotoBold().timeout(
        const Duration(seconds: 1),
      );
      final italic = await PdfGoogleFonts.robotoItalic().timeout(
        const Duration(seconds: 1),
      );
      final boldItalic = await PdfGoogleFonts.robotoBoldItalic().timeout(
        const Duration(seconds: 1),
      );
      _cachedFonts = (regular, bold, italic, boldItalic);
      return _cachedFonts!;
    } catch (_) {
      _cachedFonts = (
        pw.Font.helvetica(),
        pw.Font.helveticaBold(),
        pw.Font.helveticaOblique(),
        pw.Font.helveticaBoldOblique(),
      );
      return _cachedFonts!;
    }
  }

  /// Generates PDF binary bytes for a [document].
  static Future<Uint8List> generatePdf({
    required NoteDocument document,
    PageTemplate template = PageTemplate.ruled,
    PdfExportMode mode = PdfExportMode.pageBounds,
    PdfPageFormat pageFormat = defaultPageFormat,
  }) async {
    final pdf = pw.Document();

    final (regularFont, boldFont, italicFont, boldItalicFont) = await _getFonts();

    final theme = pw.ThemeData.withFont(
      base: regularFont,
      bold: boldFont,
      italic: italicFont,
      boldItalic: boldItalicFont,
    );

    for (final page in document.pages) {
      pdf.addPage(
        pw.Page(
          pageFormat: pageFormat,
          theme: theme,
          build: (pw.Context context) {
            return _buildPdfPage(
              page: page,
              template: template,
              mode: mode,
              isInfinite: document.canvasMode.isInfinite,
              pageFormat: pageFormat,
              regularFont: regularFont,
            );
          },
        ),
      );
    }

    return pdf.save();
  }

  /// Exports and shares the document PDF file via native platform dialogue or web download.
  static Future<bool> exportPdf({
    required NoteDocument document,
    PageTemplate template = PageTemplate.ruled,
    PdfExportMode mode = PdfExportMode.pageBounds,
  }) async {
    final bytes = await generatePdf(
      document: document,
      template: template,
      mode: mode,
    );

    final sanitizedTitle = document.title.trim().replaceAll(
      RegExp(r'[\\/:*?"<>|]'),
      '_',
    );
    final filename =
        sanitizedTitle.isEmpty ? 'Untitled_Note.pdf' : '$sanitizedTitle.pdf';

    return Printing.sharePdf(
      bytes: bytes,
      filename: filename,
    );
  }

  /// Builds a single PDF page with background, images, vector strokes, and rich text.
  static pw.Widget _buildPdfPage({
    required NotePage page,
    required PageTemplate template,
    required PdfExportMode mode,
    bool isInfinite = false,
    required PdfPageFormat pageFormat,
    required pw.Font regularFont,
  }) {
    final standardWidth = AppConstants.defaultPageSize.width;
    final standardHeight = AppConstants.defaultPageSize.height;

    double scale = 1.0;
    double offsetX = 0.0;
    double offsetY = 0.0;

    if (isInfinite) {
      // In Infinite Canvas Mode, fit precisely whatever content exists on the canvas:
      final exactBounds = _calculateExactContentBounds(page);

      if (exactBounds == null) {
        // Page has no content: clean empty page
        scale = 1.0;
        offsetX = 32.0;
        offsetY = 32.0;
      } else {
        const margin = 32.0;
        final availableWidth = pageFormat.width - (margin * 2);
        final availableHeight = pageFormat.height - (margin * 2);

        // If content dimensions exceed the printable page area, scale down proportionally:
        if (exactBounds.width > availableWidth ||
            exactBounds.height > availableHeight) {
          final scaleX = availableWidth / exactBounds.width;
          final scaleY = availableHeight / exactBounds.height;
          scale = min(1.0, min(scaleX, scaleY));
        } else {
          // Content fits without shrinking: keep 1:1 natural readable size!
          scale = 1.0;
        }

        // Anchor content cleanly starting at top-left margin (32pt)
        offsetX = margin - (exactBounds.left * scale);
        offsetY = margin - (exactBounds.top * scale);
      }
    } else if (mode == PdfExportMode.shrinkToFit) {
      final contentBounds = _calculatePageContentBounds(page);

      // Check if content overflows standard page boundary
      final hasOverflow = contentBounds.left < 0 ||
          contentBounds.top < 0 ||
          contentBounds.right > standardWidth ||
          contentBounds.bottom > standardHeight;

      if (hasOverflow && contentBounds.width > 0 && contentBounds.height > 0) {
        const margin = 24.0;
        final availableWidth = pageFormat.width - (margin * 2);
        final availableHeight = pageFormat.height - (margin * 2);

        final scaleX = availableWidth / contentBounds.width;
        final scaleY = availableHeight / contentBounds.height;
        scale = min(1.0, min(scaleX, scaleY));

        offsetX = margin +
            ((availableWidth - (contentBounds.width * scale)) / 2.0) -
            (contentBounds.left * scale);
        offsetY = margin +
            ((availableHeight - (contentBounds.height * scale)) / 2.0) -
            (contentBounds.top * scale);
      }
    }

    return pw.Stack(
      children: [
        // 1. Page Background (Canvas paper sheet & template lines)
        _buildBackground(
          template: template,
          mode: mode,
          isInfinite: isInfinite,
          scale: scale,
          offsetX: offsetX,
          offsetY: offsetY,
          pageFormat: pageFormat,
        ),

        // 2. Images Layer (rendered beneath inking annotations)
        ..._buildImages(
          images: page.images,
          scale: scale,
          offsetX: offsetX,
          offsetY: offsetY,
        ),

        // 3. Vector Inking Strokes (highlighters in pass 1, pens/fountain in pass 2)
        pw.CustomPaint(
          size: PdfPoint(pageFormat.width, pageFormat.height),
          painter: (PdfGraphics canvas, PdfPoint size) {
            _paintStrokes(
              canvas: canvas,
              strokes: page.strokes,
              scale: scale,
              offsetX: offsetX,
              offsetY: offsetY,
              pageHeight: pageFormat.height,
            );
          },
        ),

        // 4. Rich Text Boxes Layer
        ..._buildTextBoxes(
          textBoxes: page.textBoxes,
          scale: scale,
          offsetX: offsetX,
          offsetY: offsetY,
          regularFont: regularFont,
        ),
      ],
    );
  }

  /// Calculates the exact bounding rectangle enclosing all content on the page
  /// (strokes, images, text boxes). Returns null if the page has no content.
  static material.Rect? _calculateExactContentBounds(NotePage page) {
    material.Rect? bounds;

    for (final stroke in page.strokes) {
      if (stroke.points.isNotEmpty) {
        bounds = bounds == null
            ? stroke.bounds
            : bounds.expandToInclude(stroke.bounds);
      }
    }

    for (final img in page.images) {
      bounds = bounds == null ? img.bounds : bounds.expandToInclude(img.bounds);
    }

    for (final box in page.textBoxes) {
      bounds = bounds == null ? box.bounds : bounds.expandToInclude(box.bounds);
    }

    return bounds;
  }

  /// Calculates the union bounding rectangle of all page contents.
  static material.Rect _calculatePageContentBounds(NotePage page) {
    material.Rect bounds = material.Rect.fromLTWH(
      0,
      0,
      AppConstants.defaultPageSize.width,
      AppConstants.defaultPageSize.height,
    );

    for (final stroke in page.strokes) {
      if (stroke.points.isNotEmpty) {
        bounds = bounds.expandToInclude(stroke.bounds);
      }
    }

    for (final img in page.images) {
      bounds = bounds.expandToInclude(img.bounds);
    }

    for (final box in page.textBoxes) {
      bounds = bounds.expandToInclude(box.bounds);
    }

    return bounds;
  }

  /// Builds the background widget including paper fill and ruled/grid lines.
  static pw.Widget _buildBackground({
    required PageTemplate template,
    required PdfExportMode mode,
    bool isInfinite = false,
    required double scale,
    required double offsetX,
    required double offsetY,
    required PdfPageFormat pageFormat,
  }) {
    if (isInfinite) {
      // In Infinite Canvas Mode, the entire PDF page is seamless paper without
      // pasteboard containers or miniature sheet borders.
      return pw.Stack(
        children: [
          // Solid white paper covering the entire PDF page
          pw.Container(
            width: pageFormat.width,
            height: pageFormat.height,
            color: PdfColors.white,
          ),

          // Ruled or Grid Lines covering the entire PDF page
          if (template != PageTemplate.blank)
            pw.CustomPaint(
              size: PdfPoint(pageFormat.width, pageFormat.height),
              painter: (PdfGraphics canvas, PdfPoint size) {
                const lineSpacing = 32.0;
                final lineColor = template == PageTemplate.ruled
                    ? PdfColor.fromInt(AppColors.ruledLine.toARGB32())
                    : PdfColor.fromInt(AppColors.gridLine.toARGB32());

                canvas.setColor(lineColor);
                canvas.setLineWidth(0.5);

                // Horizontal lines across entire page width
                for (double y = lineSpacing;
                    y < pageFormat.height;
                    y += lineSpacing) {
                  final pdfY = pageFormat.height - y;
                  canvas.moveTo(0, pdfY);
                  canvas.lineTo(pageFormat.width, pdfY);
                  canvas.strokePath();
                }

                // Vertical lines for Grid across entire page height
                if (template == PageTemplate.grid) {
                  for (double x = lineSpacing;
                      x < pageFormat.width;
                      x += lineSpacing) {
                    canvas.moveTo(x, pageFormat.height);
                    canvas.lineTo(x, 0);
                    canvas.strokePath();
                  }
                }
              },
            ),
        ],
      );
    }

    final standardWidth = AppConstants.defaultPageSize.width;
    final standardHeight = AppConstants.defaultPageSize.height;

    final sheetLeft = offsetX;
    final sheetTop = offsetY;
    final sheetWidth = standardWidth * scale;
    final sheetHeight = standardHeight * scale;

    return pw.Stack(
      children: [
        // Canvas pasteboard base container
        pw.Container(
          width: pageFormat.width,
          height: pageFormat.height,
          color: mode == PdfExportMode.shrinkToFit && scale < 1.0
              ? const PdfColor(0.96, 0.96, 0.97)
              : PdfColors.white,
        ),

        // Sheet area (white background with subtle border if scaled)
        pw.Positioned(
          left: sheetLeft,
          top: sheetTop,
          child: pw.Container(
            width: sheetWidth,
            height: sheetHeight,
            decoration: pw.BoxDecoration(
              color: PdfColors.white,
              border: (mode == PdfExportMode.shrinkToFit && scale < 1.0)
                  ? pw.Border.all(
                      color: const PdfColor(0.82, 0.82, 0.85),
                      width: 1,
                    )
                  : null,
            ),
          ),
        ),

        // Ruled or Grid Lines
        if (template != PageTemplate.blank)
          pw.CustomPaint(
            size: PdfPoint(pageFormat.width, pageFormat.height),
            painter: (PdfGraphics canvas, PdfPoint size) {
              final lineSpacing = 32.0 * scale;
              final lineColor = template == PageTemplate.ruled
                  ? PdfColor.fromInt(AppColors.ruledLine.toARGB32())
                  : PdfColor.fromInt(AppColors.gridLine.toARGB32());

              canvas.setColor(lineColor);
              canvas.setLineWidth(0.5);

              // Horizontal lines
              for (double y = sheetTop + lineSpacing;
                  y < sheetTop + sheetHeight;
                  y += lineSpacing) {
                final pdfY = pageFormat.height - y;
                canvas.moveTo(sheetLeft, pdfY);
                canvas.lineTo(sheetLeft + sheetWidth, pdfY);
                canvas.strokePath();
              }

              // Vertical lines for Grid
              if (template == PageTemplate.grid) {
                for (double x = sheetLeft + lineSpacing;
                    x < sheetLeft + sheetWidth;
                    x += lineSpacing) {
                  final pdfYTop = pageFormat.height - sheetTop;
                  final pdfYBottom = pageFormat.height - (sheetTop + sheetHeight);
                  canvas.moveTo(x, pdfYTop);
                  canvas.lineTo(x, pdfYBottom);
                  canvas.strokePath();
                }
              }
            },
          ),
      ],
    );
  }

  /// Builds image widgets placed on the page.
  static List<pw.Widget> _buildImages({
    required List<NoteImage> images,
    required double scale,
    required double offsetX,
    required double offsetY,
  }) {
    final widgets = <pw.Widget>[];

    for (final img in images) {
      if (img.bytes.isEmpty) continue;
      try {
        final left = (img.position.dx * scale) + offsetX;
        final top = (img.position.dy * scale) + offsetY;
        final width = max(4.0, img.width * scale);
        final height = max(4.0, img.height * scale);

        final memoryImage = pw.MemoryImage(img.bytes);

        widgets.add(
          pw.Positioned(
            left: left,
            top: top,
            child: pw.SizedBox(
              width: width,
              height: height,
              child: pw.Image(
                memoryImage,
                fit: pw.BoxFit.fill,
              ),
            ),
          ),
        );
      } catch (_) {
        // Skip unrenderable corrupted image bytes cleanly
      }
    }

    return widgets;
  }

  /// Paints vector inking strokes (highlighters first, followed by pens and fountain pens).
  static void _paintStrokes({
    required PdfGraphics canvas,
    required List<Stroke> strokes,
    required double scale,
    required double offsetX,
    required double offsetY,
    required double pageHeight,
  }) {
    // Pass 1: Translucent highlighters
    for (final stroke in strokes) {
      if (stroke.toolType == ToolType.highlighter) {
        _paintStroke(
          canvas: canvas,
          stroke: stroke,
          scale: scale,
          offsetX: offsetX,
          offsetY: offsetY,
          pageHeight: pageHeight,
        );
      }
    }

    // Pass 2: Ballpoint and Fountain Pens
    for (final stroke in strokes) {
      if (stroke.toolType != ToolType.highlighter) {
        _paintStroke(
          canvas: canvas,
          stroke: stroke,
          scale: scale,
          offsetX: offsetX,
          offsetY: offsetY,
          pageHeight: pageHeight,
        );
      }
    }
  }

  /// Paints an individual stroke onto the [canvas].
  static void _paintStroke({
    required PdfGraphics canvas,
    required Stroke stroke,
    required double scale,
    required double offsetX,
    required double offsetY,
    required double pageHeight,
  }) {
    if (stroke.points.isEmpty) return;

    final isHighlighter = stroke.toolType == ToolType.highlighter;
    final isFountain = stroke.toolType == ToolType.fountainPen;

    // Map stroke color and alpha
    final color = stroke.color;
    final alpha = isHighlighter && color.a >= 1.0 ? 0.38 : color.a;
    final pdfColor = PdfColor(color.r, color.g, color.b, alpha);

    final strokeWidth = max(0.5, stroke.strokeWidth * scale);

    if (isFountain) {
      _paintFountainStroke(
        canvas: canvas,
        points: stroke.points,
        pdfColor: pdfColor,
        baseWidth: strokeWidth,
        scale: scale,
        offsetX: offsetX,
        offsetY: offsetY,
        pageHeight: pageHeight,
      );
      return;
    }

    // Regular Pen or Highlighter
    canvas.setColor(pdfColor);
    canvas.setLineWidth(strokeWidth);
    canvas.setLineCap(
      isHighlighter ? PdfLineCap.square : PdfLineCap.round,
    );
    canvas.setLineJoin(
      isHighlighter ? PdfLineJoin.bevel : PdfLineJoin.round,
    );

    if (stroke.points.length == 1) {
      final p = stroke.points.first;
      final pdfX = (p.dx * scale) + offsetX;
      final pdfY = pageHeight - ((p.dy * scale) + offsetY);
      final r = strokeWidth / 2.0;

      canvas.setFillColor(pdfColor);
      canvas.drawEllipse(pdfX, pdfY, r, r);
      canvas.fillPath();
      return;
    }

    final p0 = stroke.points.first;
    final x0 = (p0.dx * scale) + offsetX;
    final y0 = pageHeight - ((p0.dy * scale) + offsetY);
    canvas.moveTo(x0, y0);

    for (int i = 1; i < stroke.points.length; i++) {
      final pi = stroke.points[i];
      final xi = (pi.dx * scale) + offsetX;
      final yi = pageHeight - ((pi.dy * scale) + offsetY);
      canvas.lineTo(xi, yi);
    }

    canvas.strokePath();
  }

  /// Paints fountain pen stroke ribbons responding to pressure sensitivity.
  static void _paintFountainStroke({
    required PdfGraphics canvas,
    required List<StrokePoint> points,
    required PdfColor pdfColor,
    required double baseWidth,
    required double scale,
    required double offsetX,
    required double offsetY,
    required double pageHeight,
  }) {
    canvas.setFillColor(pdfColor);

    if (points.length == 1) {
      final p = points.first;
      final pdfX = (p.dx * scale) + offsetX;
      final pdfY = pageHeight - ((p.dy * scale) + offsetY);
      final r = baseWidth * (0.25 + (0.9 * p.pressure)) / 2.0;
      canvas.drawEllipse(pdfX, pdfY, r, r);
      canvas.fillPath();
      return;
    }

    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];

      final r1 = baseWidth * (0.25 + (0.9 * p1.pressure)) / 2.0;
      final r2 = baseWidth * (0.25 + (0.9 * p2.pressure)) / 2.0;

      final diffX = (p2.dx - p1.dx) * scale;
      final diffY = (p2.dy - p1.dy) * scale;
      final dist = sqrt((diffX * diffX) + (diffY * diffY));
      if (dist < 0.1) continue;

      // Normal vector
      final normalX = -diffY / dist;
      final normalY = diffX / dist;

      // Canvas coordinates
      final p1aX = (p1.dx * scale) + offsetX + (normalX * r1);
      final p1aY = (p1.dy * scale) + offsetY + (normalY * r1);

      final p1bX = (p1.dx * scale) + offsetX - (normalX * r1);
      final p1bY = (p1.dy * scale) + offsetY - (normalY * r1);

      final p2aX = (p2.dx * scale) + offsetX + (normalX * r2);
      final p2aY = (p2.dy * scale) + offsetY + (normalY * r2);

      final p2bX = (p2.dx * scale) + offsetX - (normalX * r2);
      final p2bY = (p2.dy * scale) + offsetY - (normalY * r2);

      // Inverted PDF Y coordinates
      final pdf1aY = pageHeight - p1aY;
      final pdf2aY = pageHeight - p2aY;
      final pdf2bY = pageHeight - p2bY;
      final pdf1bY = pageHeight - p1bY;

      canvas.moveTo(p1aX, pdf1aY);
      canvas.lineTo(p2aX, pdf2aY);
      canvas.lineTo(p2bX, pdf2bY);
      canvas.lineTo(p1bX, pdf1bY);
      canvas.closePath();
      canvas.fillPath();

      // Circle caps for smooth joins
      final pdfP1X = (p1.dx * scale) + offsetX;
      final pdfP1Y = pageHeight - ((p1.dy * scale) + offsetY);
      canvas.drawEllipse(pdfP1X, pdfP1Y, r1, r1);
      canvas.fillPath();

      final pdfP2X = (p2.dx * scale) + offsetX;
      final pdfP2Y = pageHeight - ((p2.dy * scale) + offsetY);
      canvas.drawEllipse(pdfP2X, pdfP2Y, r2, r2);
      canvas.fillPath();
    }
  }

  /// Builds rich text box widgets placed on the page.
  static List<pw.Widget> _buildTextBoxes({
    required List<NoteTextBox> textBoxes,
    required double scale,
    required double offsetX,
    required double offsetY,
    required pw.Font regularFont,
  }) {
    final widgets = <pw.Widget>[];

    for (final box in textBoxes) {
      if (box.text.trim().isEmpty) continue;

      final left = (box.position.dx * scale) + offsetX;
      final top = (box.position.dy * scale) + offsetY;
      final boxWidth = max(40.0, box.width * scale);

      final isRtl = box.effectiveTextDirection == material.TextDirection.rtl;
      final pwDir = isRtl ? pw.TextDirection.rtl : pw.TextDirection.ltr;

      final spans = _buildPdfTextSpans(
        text: box.text,
        spans: box.spans,
        defaultFontSize: box.defaultFontSize ?? 15.0,
        headingDefaultFontSizes: box.headingDefaultFontSizes,
        scale: scale,
        regularFont: regularFont,
      );

      widgets.add(
        pw.Positioned(
          left: left,
          top: top,
          child: pw.SizedBox(
            width: boxWidth,
            child: pw.Directionality(
              textDirection: pwDir,
              child: pw.RichText(
                text: pw.TextSpan(children: spans),
              ),
            ),
          ),
        ),
      );
    }

    return widgets;
  }

  /// Converts a [text] and its [RichTextSpan] list into elementary disjoint [pw.TextSpan] slices.
  static List<pw.InlineSpan> _buildPdfTextSpans({
    required String text,
    required List<RichTextSpan> spans,
    double defaultFontSize = 15.0,
    Map<HeadingLevel, double>? headingDefaultFontSizes,
    required double scale,
    required pw.Font regularFont,
  }) {
    if (text.isEmpty) return const [];

    final isStandardFont = regularFont is! pw.TtfFont;

    // Helper to filter unsupported non-Latin characters if standard Helvetica fallback is used
    String safeText(String input) {
      if (!isStandardFont) return input;
      final buffer = StringBuffer();
      for (int i = 0; i < input.length; i++) {
        final code = input.codeUnitAt(i);
        buffer.write(code <= 255 ? input[i] : '?');
      }
      return buffer.toString();
    }

    if (spans.isEmpty) {
      return [
        pw.TextSpan(
          text: safeText(text),
          style: pw.TextStyle(
            fontSize: defaultFontSize * scale,
            color: PdfColors.black,
          ),
        ),
      ];
    }

    // 1. Boundary decomposition
    final Set<int> boundarySet = {0, text.length};
    for (final s in spans) {
      if (s.start >= 0 && s.start <= text.length) boundarySet.add(s.start);
      if (s.end >= 0 && s.end <= text.length) boundarySet.add(s.end);
    }

    final boundaries = boundarySet.toList()..sort();
    final result = <pw.InlineSpan>[];

    // 2. Iterate each elementary disjoint slice [segStart, segEnd]
    for (int i = 0; i < boundaries.length - 1; i++) {
      final segStart = boundaries[i];
      final segEnd = boundaries[i + 1];
      if (segStart >= segEnd) continue;

      final segText = safeText(text.substring(segStart, segEnd));

      bool isBold = false;
      bool isItalic = false;
      bool isUnderline = false;
      bool isStrikethrough = false;
      material.Color? segColor;
      material.Color? segHighlight;
      HeadingLevel segHeading = HeadingLevel.none;
      double? segFontSize;

      for (final s in spans) {
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

      double effectiveFontSize = segFontSize ??
          (headingDefaultFontSizes?[segHeading] ??
              (segHeading != HeadingLevel.none
                  ? segHeading.defaultFontSize
                  : defaultFontSize));

      final pwDecoration = pw.TextDecoration.combine([
        if (isUnderline) pw.TextDecoration.underline,
        if (isStrikethrough) pw.TextDecoration.lineThrough,
      ]);

      final pwColor = segColor != null
          ? PdfColor.fromInt(segColor.toARGB32())
          : PdfColors.black;

      final pwHighlight = segHighlight != null
          ? pw.BoxDecoration(color: PdfColor.fromInt(segHighlight.toARGB32()))
          : null;

      result.add(
        pw.TextSpan(
          text: segText,
          style: pw.TextStyle(
            fontSize: effectiveFontSize * scale,
            fontWeight: isBold || segHeading != HeadingLevel.none
                ? pw.FontWeight.bold
                : pw.FontWeight.normal,
            fontStyle: isItalic ? pw.FontStyle.italic : pw.FontStyle.normal,
            decoration: pwDecoration == pw.TextDecoration.none ? null : pwDecoration,
            color: pwColor,
            background: pwHighlight,
          ),
        ),
      );
    }

    return result;
  }
}
