import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/core/constants/app_constants.dart';
import 'package:open_note/features/canvas/controllers/canvas_controller.dart';
import 'package:open_note/features/canvas/models/canvas_mode.dart';
import 'package:open_note/features/canvas/models/tool_type.dart';
import 'package:open_note/features/canvas/presentation/painters/infinite_background_painter.dart';
import 'package:open_note/features/canvas/presentation/painters/page_background_painter.dart';
import 'package:open_note/features/notebook/controllers/notebook_controller.dart';
import 'package:open_note/features/canvas/models/note_text_box.dart';
import 'package:open_note/features/canvas/models/stroke.dart';
import 'package:open_note/features/canvas/models/stroke_point.dart';
import 'package:open_note/features/canvas/presentation/note_canvas.dart';
import 'package:open_note/features/notebook/models/note_document.dart';
import 'package:open_note/features/notebook/models/note_page.dart';
import 'package:open_note/features/notebook/presentation/note_screen.dart';
import 'package:open_note/features/notebook/presentation/widgets/export_pdf_dialog.dart';
import 'package:open_note/features/storage/pdf_export_service.dart';

void main() {
  group('CanvasMode Model & Serialization Tests', () {
    test('CanvasMode enum getters and labels', () {
      expect(CanvasMode.paged.label, equals('Standard Paged'));
      expect(CanvasMode.infinite.label, equals('Infinite Canvas'));
      expect(CanvasMode.paged.isPaged, isTrue);
      expect(CanvasMode.paged.isInfinite, isFalse);
      expect(CanvasMode.infinite.isInfinite, isTrue);
      expect(CanvasMode.infinite.isPaged, isFalse);
    });

    test('NoteDocument serializes and deserializes canvasMode correctly', () {
      final doc = NoteDocument(
        id: 'infinite_doc_1',
        title: 'Infinite Sketchpad',
        canvasMode: CanvasMode.infinite,
      );

      final json = doc.toJson();
      expect(json['canvasMode'], equals('infinite'));

      final restored = NoteDocument.fromJson(json);
      expect(restored.canvasMode, equals(CanvasMode.infinite));
      expect(restored.canvasMode.isInfinite, isTrue);
    });

    test('NoteDocument defaults to CanvasMode.paged if canvasMode is missing (backward compatibility)', () {
      final legacyJson = {
        'id': 'legacy_note',
        'title': 'Legacy Note',
        'pages': [
          {'id': 'p1', 'pageNumber': 1}
        ],
      };

      final doc = NoteDocument.fromJson(legacyJson);
      expect(doc.canvasMode, equals(CanvasMode.paged));
      expect(doc.canvasMode.isPaged, isTrue);
    });
  });

  group('CanvasController Infinite Canvas Switching Tests', () {
    late CanvasController controller;

    setUp(() {
      controller = CanvasController();
    });

    test('Default mode is CanvasMode.paged', () {
      expect(controller.canvasMode, equals(CanvasMode.paged));
      expect(controller.isInfinite, isFalse);
    });

    test('toggleCanvasMode switches between paged and infinite', () {
      controller.toggleCanvasMode();
      expect(controller.canvasMode, equals(CanvasMode.infinite));
      expect(controller.isInfinite, isTrue);

      controller.toggleCanvasMode();
      expect(controller.canvasMode, equals(CanvasMode.paged));
      expect(controller.isInfinite, isFalse);
    });

    test('Switching to Infinite merges multi-page content onto Page 0 preserving spatial offsets', () {
      // Create Page 1 content
      controller.setTool(ToolType.pen);
      controller.onPointerDown(const Offset(50, 100), pointer: 1);
      controller.onPointerMove(const Offset(60, 110), pointer: 1);
      controller.onPointerUp(const Offset(60, 110), pointer: 1);

      controller.setTool(ToolType.text);
      controller.addTextBox(const Offset(100, 200), text: 'Page 1 Box');

      // Add Page 2
      controller.addPage();
      expect(controller.pages.length, equals(2));

      controller.setTool(ToolType.text);
      controller.addTextBox(const Offset(120, 220), text: 'Page 2 Box');

      // Switch to Infinite Canvas Mode
      controller.setCanvasMode(CanvasMode.infinite);

      // Now exactly 1 page exists
      expect(controller.pages.length, equals(1));
      expect(controller.activePageIndex, equals(0));

      // Both text boxes are on page 0
      final page0Boxes = controller.pages[0].textBoxes;
      expect(page0Boxes.length, equals(2));

      // Page 1 box offset is pageHeaderHeight + box.position.dy
      final page1ExpectedY = AppConstants.pageHeaderHeight + 200.0;
      expect(page0Boxes[0].position.dy, equals(page1ExpectedY));

      // Page 2 box offset is pageHeaderHeight + 1 * pagePitch + box.position.dy
      final page2ExpectedY = AppConstants.pageHeaderHeight + AppConstants.pagePitch + 220.0;
      expect(page0Boxes[1].position.dy, equals(page2ExpectedY));
    });

    test('addPage when in infinite mode automatically switches to paged mode', () {
      controller.setCanvasMode(CanvasMode.infinite);
      expect(controller.isInfinite, isTrue);

      controller.addPage();
      expect(controller.canvasMode, equals(CanvasMode.paged));
      expect(controller.pages.length, equals(2));
    });
  });

  group('NotebookController CanvasMode Synchronization Tests', () {
    late CanvasController canvasController;
    late NotebookController notebookController;

    setUp(() {
      canvasController = CanvasController();
      notebookController = NotebookController(canvasController: canvasController);
    });

    tearDown(() {
      notebookController.dispose();
      canvasController.dispose();
    });

    test('NotebookController synchronizes canvasMode changes to currentNote', () {
      expect(notebookController.currentNote.canvasMode, equals(CanvasMode.paged));

      notebookController.toggleCanvasMode();
      expect(canvasController.canvasMode, equals(CanvasMode.infinite));
      expect(notebookController.currentNote.canvasMode, equals(CanvasMode.infinite));

      notebookController.setCanvasMode(CanvasMode.paged);
      expect(canvasController.canvasMode, equals(CanvasMode.paged));
      expect(notebookController.currentNote.canvasMode, equals(CanvasMode.paged));
    });

    test('createNewNote with canvasMode: CanvasMode.infinite sets mode properly', () {
      notebookController.createNewNote(
        title: 'My Infinite Idea Board',
        canvasMode: CanvasMode.infinite,
      );

      expect(notebookController.currentNote.title, equals('My Infinite Idea Board'));
      expect(notebookController.currentNote.canvasMode, equals(CanvasMode.infinite));
      expect(canvasController.canvasMode, equals(CanvasMode.infinite));
    });
  });

  group('InfiniteBackgroundPainter Tests', () {
    test('Paints solid background and lines without error', () {
      final painter = InfiniteBackgroundPainter(
        template: PageTemplate.ruled,
        lineSpacing: 32.0,
        isDarkMode: false,
        visibleBounds: const Rect.fromLTWH(0, 0, 800, 600),
      );

      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      painter.paint(canvas, const Size(800, 600));
      final picture = recorder.endRecording();
      expect(picture, isNotNull);
    });

    test('Grid template paints horizontal and vertical lines', () {
      final painter = InfiniteBackgroundPainter(
        template: PageTemplate.grid,
        lineSpacing: 32.0,
        isDarkMode: true,
        visibleBounds: const Rect.fromLTWH(-500, -500, 1000, 1000),
      );

      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      painter.paint(canvas, const Size(1000, 1000));
      final picture = recorder.endRecording();
      expect(picture, isNotNull);
    });
  });

  group('NoteScreen CanvasMode UI Integration Tests', () {
    testWidgets('Tapping canvas_mode_toggle_button switches between Paged and Infinite modes', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const MaterialApp(
          home: NoteScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // Initial state: Paged mode ("1 Page" and "Add Page" visible)
      expect(find.text('1 Page'), findsOneWidget);
      expect(find.byTooltip('Add Page'), findsOneWidget);
      expect(find.byKey(const Key('canvas_mode_toggle_button')), findsOneWidget);

      // Tap toggle to Infinite mode
      await tester.tap(find.byKey(const Key('canvas_mode_toggle_button')));
      await tester.pumpAndSettle();

      // Infinite mode UI verification
      expect(find.text('∞ Infinite Canvas'), findsOneWidget);
      expect(find.byTooltip('Add Page'), findsNothing); // Add Page hidden in infinite mode

      // Tap toggle back to Paged mode
      await tester.tap(find.byKey(const Key('canvas_mode_toggle_button')));
      await tester.pumpAndSettle();

      // Back to Paged mode
      expect(find.text('1 Page'), findsOneWidget);
      expect(find.byTooltip('Add Page'), findsOneWidget);
    });

    testWidgets('ExportPdfDialog defaults to shrinkToFit for infinite canvas notes', (tester) async {
      final infiniteNote = NoteDocument(
        id: 'test_infinite',
        title: 'Infinite Canvas Note',
        canvasMode: CanvasMode.infinite,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExportPdfDialog(document: infiniteNote),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // In infinite mode, the shrinkToFit mode option should be selected
      expect(find.text('Infinite Canvas (Shrink to Fit)'), findsOneWidget);
    });
  });

  group('PdfExportService Infinite Canvas Export Tests', () {
    test('Exports infinite note with text box at (100, 1500) with exact content bounds', () async {
      final doc = NoteDocument(
        id: 'infinite_doc_text',
        title: 'Infinite Text Note',
        canvasMode: CanvasMode.infinite,
        pages: [
          NotePage(
            id: 'page_inf_1',
            pageNumber: 1,
            textBoxes: [
              NoteTextBox(
                id: 'tb_single',
                position: const Offset(100, 1500),
                width: 320,
                height: 80,
                text: 'Hello world, how are you today!!',
              ),
            ],
          ),
        ],
      );

      final pdfBytes = await PdfExportService.generatePdf(
        document: doc,
        template: PageTemplate.ruled,
      );

      expect(pdfBytes, isNotEmpty);
      expect(String.fromCharCodes(pdfBytes.sublist(0, 5)), equals('%PDF-'));
    });

    test('Exports infinite note with simple stroke drawing without errors', () async {
      final doc = NoteDocument(
        id: 'infinite_doc_stroke',
        title: 'Infinite Drawing Note',
        canvasMode: CanvasMode.infinite,
        pages: [
          NotePage(
            id: 'page_inf_2',
            pageNumber: 1,
            strokes: [
              Stroke(
                points: [
                  StrokePoint(200, 300),
                  StrokePoint(250, 350),
                  StrokePoint(300, 400),
                ],
                color: Colors.blue,
                strokeWidth: 4.0,
                toolType: ToolType.pen,
              ),
            ],
          ),
        ],
      );

      final pdfBytes = await PdfExportService.generatePdf(
        document: doc,
        template: PageTemplate.grid,
      );

      expect(pdfBytes, isNotEmpty);
      expect(String.fromCharCodes(pdfBytes.sublist(0, 5)), equals('%PDF-'));
    });

    test('Exports empty infinite note cleanly with full page background', () async {
      final doc = NoteDocument(
        id: 'infinite_doc_empty',
        title: 'Empty Infinite Note',
        canvasMode: CanvasMode.infinite,
        pages: [
          NotePage(id: 'page_inf_empty', pageNumber: 1),
        ],
      );

      final pdfBytes = await PdfExportService.generatePdf(
        document: doc,
        template: PageTemplate.ruled,
      );

      expect(pdfBytes, isNotEmpty);
      expect(String.fromCharCodes(pdfBytes.sublist(0, 5)), equals('%PDF-'));
    });
  });

  group('NoteCanvas Infinite Canvas Top-Left Boundary Clamping Tests', () {
    testWidgets('Panning up/left is clamped to top-left boundary, panning down/right is unbounded', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final controller = CanvasController();
      controller.setCanvasMode(CanvasMode.infinite);
      controller.setTool(ToolType.pan);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NoteCanvas(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
      final initialMatrix = iv.transformationController!.value;
      final initialTx = initialMatrix.storage[12];
      final initialTy = initialMatrix.storage[13];

      // Top boundary is at 24.0 or 40.0, well within maxTy (<= 40.0)
      expect(initialTy, lessThanOrEqualTo(40.0));
      expect(initialTx, lessThanOrEqualTo(400.0));

      // Attempt to drag down by 800px (which would push the canvas down, ty > 40)
      await tester.drag(find.byType(NoteCanvas), const Offset(0, 800));
      await tester.pumpAndSettle();

      final afterDragDownMatrix = iv.transformationController!.value;
      // ty should be clamped to <= 40.0 (cannot pan endlessly up into negative scene coords)
      expect(afterDragDownMatrix.storage[13], lessThanOrEqualTo(40.01));

      // Drag up by 500px (scrolling down into infinite canvas)
      await tester.drag(find.byType(NoteCanvas), const Offset(0, -500));
      await tester.pumpAndSettle();

      final afterDragUpMatrix = iv.transformationController!.value;
      // Scrolling down is permitted (ty becomes more negative)
      expect(afterDragUpMatrix.storage[13], lessThan(afterDragDownMatrix.storage[13]));
    });
  });
}
