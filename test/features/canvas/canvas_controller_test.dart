import 'dart:math';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/core/constants/app_constants.dart';
import 'package:open_note/core/theme/app_colors.dart';
import 'package:open_note/features/canvas/controllers/canvas_controller.dart';
import 'package:open_note/features/canvas/models/stroke.dart';
import 'package:open_note/features/canvas/models/stroke_point.dart';
import 'package:open_note/features/canvas/models/tool_type.dart';
import 'package:open_note/features/canvas/presentation/widgets/selection_toolbar.dart';
import 'package:open_note/features/canvas/services/eraser_service.dart';
import 'package:open_note/features/canvas/services/lasso_service.dart';

void main() {
  group('CanvasController Tests', () {
    late CanvasController controller;

    setUp(() {
      controller = CanvasController();
    });

    tearDown(() {
      controller.dispose();
    });

    test('Initial state is pen with default width and empty strokes', () {
      expect(controller.activeTool, ToolType.pen);
      expect(controller.strokes, isEmpty);
      expect(controller.strokeWidth, 3.5);
      expect(controller.canUndo, isFalse);
      expect(controller.canRedo, isFalse);
    });

    test('Stroke width and color adjust correctly and persist per tool', () {
      // Pen settings
      controller.setStrokeWidth(6.0);
      controller.setColor(Colors.blue);
      expect(controller.strokeWidth, 6.0);
      expect(controller.activeColor, Colors.blue);

      // Switch to highlighter: should use highlighter defaults
      controller.setTool(ToolType.highlighter);
      expect(controller.strokeWidth, 22.0);
      expect(controller.activeColor, AppColors.highlighterPalette.first);

      // Change highlighter width
      controller.setStrokeWidth(30.0);
      expect(controller.strokeWidth, 30.0);

      // Switch back to pen: should restore pen settings
      controller.setTool(ToolType.pen);
      expect(controller.strokeWidth, 6.0);
      expect(controller.activeColor, Colors.blue);
    });

    test('addCustomColor adds to customColors and updates activeColor', () {
      const customTeal = Color(0xFF009688);
      controller.addCustomColor(customTeal);

      expect(controller.customColors.contains(customTeal), isTrue);
      expect(controller.activeColor, customTeal);

      // Adding another color keeps most recent first
      const customPurple = Color(0xFF9C27B0);
      controller.addCustomColor(customPurple);
      expect(controller.customColors.first, customPurple);
      expect(controller.activeColor, customPurple);
    });

    test('Drawing a stroke adds to strokes and supports undo/redo', () {
      controller.onPointerDown(const Offset(10, 10));
      controller.onPointerMove(const Offset(20, 20));
      controller.onPointerUp(const Offset(30, 30));

      expect(controller.strokes.length, 1);
      expect(controller.canUndo, isTrue);

      controller.undo();
      expect(controller.strokes, isEmpty);
      expect(controller.canRedo, isTrue);

      controller.redo();
      expect(controller.strokes.length, 1);
    });

    test('Drawing with fountain pen records pressure dynamics', () {
      controller.setTool(ToolType.fountainPen);
      controller.onPointerDown(const Offset(10, 10), pressure: 0.3);
      controller.onPointerMove(const Offset(20, 20), pressure: 0.9);
      controller.onPointerUp(const Offset(30, 30), pressure: 0.6);

      expect(controller.strokes.length, 1);
      final stroke = controller.strokes.first;
      expect(stroke.toolType, ToolType.fountainPen);
      expect(stroke.points.any((p) => p.pressure > 0.5), isTrue);
    });

    test('Palm rejection ignores touch events while stylus is active', () {
      // Stylus begins drawing
      controller.onPointerDown(
        const Offset(10, 10),
        kind: PointerDeviceKind.stylus,
      );
      expect(controller.isStylusActive, isTrue);
      expect(controller.isDrawing, isTrue);

      // Palm touches screen: should be rejected
      controller.onPointerDown(
        const Offset(200, 200),
        kind: PointerDeviceKind.touch,
      );
      // Drawing stroke should still be at original point, not jumped to palm
      expect(controller.currentStrokeNotifier.value.first.dx, 10.0);
    });

    test('Drawing with highlighter creates stroke with translucency', () {
      controller.setTool(ToolType.highlighter);
      controller.onPointerDown(const Offset(10, 10));
      controller.onPointerMove(const Offset(50, 10));
      controller.onPointerUp(const Offset(100, 10));

      expect(controller.strokes.length, 1);
      final stroke = controller.strokes.first;
      expect(stroke.toolType, ToolType.highlighter);
      expect(stroke.color.a, lessThan(1.0)); // Translucent alpha
    });

    test('Holding stylus barrel button acts as stroke eraser without changing active pen', () {
      final stroke = Stroke(
        points: const [StrokePoint(0, 0), StrokePoint(100, 100)],
        strokeWidth: 4.0,
      );
      controller.loadStrokes([stroke]);
      expect(controller.strokes.length, 1);
      expect(controller.activeTool, ToolType.pen);

      // Press down near the line with S-Pen button held (kPrimaryStylusButton)
      controller.onPointerDown(
        const Offset(51, 49),
        kind: PointerDeviceKind.stylus,
        buttons: kPrimaryStylusButton,
      );

      // Stroke should be erased
      expect(controller.strokes, isEmpty);
      // Tool should STILL be Pen (not permanently switched to eraser!)
      expect(controller.activeTool, ToolType.pen);
    });

    test('Holding W3C stylus eraser button (buttons: 32 or 33) acts as stroke eraser without changing active pen', () {
      final stroke = Stroke(
        points: const [StrokePoint(0, 0), StrokePoint(100, 100)],
        strokeWidth: 4.0,
      );
      controller.loadStrokes([stroke]);
      expect(controller.strokes.length, 1);
      expect(controller.activeTool, ToolType.pen);

      // 1. W3C button bit 32 (standard POINTER_BUTTON_ERASER)
      controller.onPointerDown(
        const Offset(51, 49),
        kind: PointerDeviceKind.stylus,
        buttons: 32,
      );
      expect(controller.strokes, isEmpty);
      expect(controller.activeTool, ToolType.pen);

      // 2. Combined tip down + eraser bit (1 | 32 = 33)
      controller.loadStrokes([stroke]);
      expect(controller.strokes.length, 1);

      controller.onPointerDown(
        const Offset(51, 49),
        kind: PointerDeviceKind.stylus,
        buttons: 33,
      );
      expect(controller.strokes, isEmpty);
      expect(controller.activeTool, ToolType.pen);
    });

    test('Drawing with invertedStylus acts as eraser without permanently changing activeTool', () {
      final stroke = Stroke(
        points: const [StrokePoint(0, 0), StrokePoint(100, 100)],
        strokeWidth: 4.0,
      );
      controller.loadStrokes([stroke]);
      expect(controller.strokes.length, 1);
      expect(controller.activeTool, ToolType.pen);

      controller.onPointerDown(
        const Offset(51, 49),
        kind: PointerDeviceKind.invertedStylus,
      );
      expect(controller.strokes, isEmpty);
      // Tool remains pen for when the user flips back to the tip!
      expect(controller.activeTool, ToolType.pen);
    });

    test('Clicking stylus eraser button mid-stroke switches to eraser and discards in-progress stroke', () {
      final stroke = Stroke(
        points: const [StrokePoint(0, 0), StrokePoint(100, 100)],
        strokeWidth: 4.0,
      );
      controller.loadStrokes([stroke]);

      // Start drawing a new stroke with pen tip
      controller.onPointerDown(
        const Offset(10, 10),
        kind: PointerDeviceKind.stylus,
        buttons: 1,
      );
      expect(controller.isDrawing, isTrue);

      // Mid-stroke: user clicks or holds eraser button (bit 32) near the existing stroke
      controller.onPointerMove(
        const Offset(51, 49),
        kind: PointerDeviceKind.stylus,
        buttons: 33,
      );
      expect(controller.isDrawing, isFalse);
      expect(controller.currentStrokeNotifier.value, isEmpty);
      // Existing stroke is erased
      expect(controller.strokes, isEmpty);

      controller.onPointerUp(
        const Offset(51, 49),
        kind: PointerDeviceKind.stylus,
        buttons: 0,
      );
      // Active tool is still Pen
      expect(controller.activeTool, ToolType.pen);
      expect(controller.strokes, isEmpty);
    });

    test('Eraser hit-test removes intersected stroke', () {
      final stroke = Stroke(
        points: const [StrokePoint(0, 0), StrokePoint(100, 100)],
        strokeWidth: 4.0,
      );
      controller.loadStrokes([stroke]);
      expect(controller.strokes.length, 1);

      controller.setTool(ToolType.strokeEraser);
      // Tap near the middle of the line (50, 50)
      controller.onPointerDown(const Offset(51, 49));

      expect(controller.strokes, isEmpty);
    });

    test('Multi-touch gestures cancel in-progress drawing and prevent drawing', () {
      // Finger 1 touches down and starts drawing
      controller.onPointerDown(
        const Offset(10, 10),
        pointer: 1,
        kind: PointerDeviceKind.touch,
      );
      expect(controller.isDrawing, isTrue);
      expect(controller.currentStrokeNotifier.value.isNotEmpty, isTrue);

      // Finger 2 touches down (multi-touch pan / pinch)
      controller.onPointerDown(
        const Offset(50, 50),
        pointer: 2,
        kind: PointerDeviceKind.touch,
      );
      // Drawing should immediately be cancelled and cleared!
      expect(controller.isDrawing, isFalse);
      expect(controller.currentStrokeNotifier.value, isEmpty);
      expect(controller.isMultiTouch, isTrue);

      // Both fingers move (panning)
      controller.onPointerMove(
        const Offset(15, 15),
        pointer: 1,
        kind: PointerDeviceKind.touch,
      );
      controller.onPointerMove(
        const Offset(55, 55),
        pointer: 2,
        kind: PointerDeviceKind.touch,
      );
      expect(controller.currentStrokeNotifier.value, isEmpty);

      // Finger 1 lifts up
      controller.onPointerUp(
        const Offset(15, 15),
        pointer: 1,
        kind: PointerDeviceKind.touch,
      );
      expect(controller.strokes, isEmpty); // No stroke was committed

      // Finger 2 lifts up
      controller.onPointerUp(
        const Offset(55, 55),
        pointer: 2,
        kind: PointerDeviceKind.touch,
      );
      expect(controller.strokes, isEmpty);
      expect(controller.isMultiTouch, isFalse);

      // Next single-finger stroke works normally
      controller.onPointerDown(
        const Offset(10, 10),
        pointer: 3,
        kind: PointerDeviceKind.touch,
      );
      controller.onPointerMove(
        const Offset(20, 20),
        pointer: 3,
        kind: PointerDeviceKind.touch,
      );
      controller.onPointerUp(
        const Offset(30, 30),
        pointer: 3,
        kind: PointerDeviceKind.touch,
      );
      expect(controller.strokes.length, 1);
    });

    test('Multi-touch in eraser mode does not accidentally erase strokes', () {
      final stroke = Stroke(
        points: const [StrokePoint(0, 0), StrokePoint(100, 100)],
        strokeWidth: 4.0,
      );
      controller.loadStrokes([stroke]);
      controller.setTool(ToolType.strokeEraser);

      // Finger 1 touches down on top of the stroke
      controller.onPointerDown(
        const Offset(50, 50),
        pointer: 1,
        kind: PointerDeviceKind.touch,
      );
      // Stroke is NOT erased yet (deferred to avoid accidental erase before finger 2 lands)
      expect(controller.strokes.length, 1);

      // Finger 2 touches down (user is two-finger panning)
      controller.onPointerDown(
        const Offset(80, 80),
        pointer: 2,
        kind: PointerDeviceKind.touch,
      );
      // Both fingers move to pan
      controller.onPointerMove(
        const Offset(55, 55),
        pointer: 1,
        kind: PointerDeviceKind.touch,
      );
      controller.onPointerMove(
        const Offset(85, 85),
        pointer: 2,
        kind: PointerDeviceKind.touch,
      );
      controller.onPointerUp(
        const Offset(55, 55),
        pointer: 1,
        kind: PointerDeviceKind.touch,
      );
      controller.onPointerUp(
        const Offset(85, 85),
        pointer: 2,
        kind: PointerDeviceKind.touch,
      );

      // Stroke is still completely intact!
      expect(controller.strokes.length, 1);
    });

    test('Area eraser splits stroke in the middle and supports undo/redo', () {
      final stroke = Stroke(
        points: const [
          StrokePoint(0, 50),
          StrokePoint(50, 50),
          StrokePoint(100, 50),
        ],
        strokeWidth: 4.0,
      );
      controller.loadStrokes([stroke]);
      expect(controller.strokes.length, 1);

      controller.setTool(ToolType.areaEraser);
      controller.setEraserRadius(10.0);

      // Swipe area eraser across the middle at (50, 50)
      controller.onPointerDown(
        const Offset(50, 50),
        kind: PointerDeviceKind.stylus,
      );

      // The single stroke should be split into 2 surviving sub-strokes!
      expect(controller.strokes.length, 2);
      expect(controller.strokes.first.points.last.dx, lessThan(50.0));
      expect(controller.strokes.last.points.first.dx, greaterThan(50.0));

      // Undo restores the original single stroke
      controller.undo();
      expect(controller.strokes.length, 1);
      expect(controller.strokes.first.points.length, 3);

      // Redo splits it again
      controller.redo();
      expect(controller.strokes.length, 2);
    });

    test('Area eraser multi-point swipe creates only ONE undo history entry', () {
      final stroke = Stroke(
        points: const [
          StrokePoint(0, 50),
          StrokePoint(50, 50),
          StrokePoint(100, 50),
        ],
        strokeWidth: 4.0,
      );
      controller.loadStrokes([stroke], clearHistory: true);
      expect(controller.strokes.length, 1);
      expect(controller.canUndo, isFalse);

      controller.setTool(ToolType.areaEraser);
      controller.setEraserRadius(10.0);

      // Multi-point swipe across the stroke (simulating high sampling rate)
      controller.onPointerDown(const Offset(40, 50));
      controller.onPointerMove(const Offset(45, 50));
      controller.onPointerMove(const Offset(50, 50));
      controller.onPointerMove(const Offset(55, 50));
      controller.onPointerMove(const Offset(60, 50));
      controller.onPointerUp(const Offset(65, 50));

      // The line was split
      expect(controller.strokes.length, 2);
      expect(controller.canUndo, isTrue);

      // Single undo should completely revert the entire swipe gesture!
      controller.undo();

      expect(controller.strokes.length, 1);
      expect(controller.strokes.first.points.length, 3);
      // Ensure there are no leftover micro-undo steps
      expect(controller.canUndo, isFalse);
    });

    test('Stylus barrel button hold-to-erase commits single undo snapshot', () {
      final stroke = Stroke(
        points: const [StrokePoint(0, 0), StrokePoint(100, 100)],
        strokeWidth: 4.0,
      );
      controller.loadStrokes([stroke], clearHistory: true);
      expect(controller.strokes.length, 1);
      expect(controller.canUndo, isFalse);
      expect(controller.activeTool, ToolType.pen);

      // Drag across with barrel button pressed
      controller.onPointerDown(
        const Offset(10, 10),
        kind: PointerDeviceKind.stylus,
        buttons: kPrimaryStylusButton,
      );
      controller.onPointerMove(
        const Offset(50, 50),
        kind: PointerDeviceKind.stylus,
        buttons: kPrimaryStylusButton,
      );
      // Lift stylus where buttons may be 0
      controller.onPointerUp(
        const Offset(50, 50),
        kind: PointerDeviceKind.stylus,
        buttons: 0,
      );

      expect(controller.strokes, isEmpty);
      expect(controller.canUndo, isTrue);

      controller.undo();
      expect(controller.strokes.length, 1);
      expect(controller.canUndo, isFalse);
    });

    test('Lasso selection encloses strokes and calculates bounds', () {
      final stroke1 = Stroke(
        points: const [StrokePoint(50, 50), StrokePoint(60, 60)],
        strokeWidth: 4.0,
      );
      final stroke2 = Stroke(
        points: const [StrokePoint(300, 300), StrokePoint(350, 350)],
        strokeWidth: 4.0,
      );
      controller.loadStrokes([stroke1, stroke2], clearHistory: true);

      controller.setTool(ToolType.lasso);

      // Draw lasso around stroke1
      controller.onPointerDown(const Offset(20, 20));
      controller.onPointerMove(const Offset(100, 20));
      controller.onPointerMove(const Offset(100, 100));
      controller.onPointerMove(const Offset(20, 100));
      controller.onPointerUp(const Offset(20, 20));

      expect(controller.hasSelection, isTrue);
      expect(controller.selectedStrokes.length, 1);
      expect(controller.selectedStrokes.first.points.first.dx, 50.0);
      expect(controller.selectionBounds, isNotNull);
    });

    test('Lasso move translates selected strokes and supports undo/redo', () {
      final stroke = Stroke(
        points: const [StrokePoint(50, 50), StrokePoint(60, 60)],
        strokeWidth: 4.0,
      );
      controller.loadStrokes([stroke], clearHistory: true);
      controller.setTool(ToolType.lasso);

      // Select stroke
      controller.onPointerDown(const Offset(20, 20));
      controller.onPointerMove(const Offset(100, 20));
      controller.onPointerMove(const Offset(100, 100));
      controller.onPointerMove(const Offset(20, 100));
      controller.onPointerUp(const Offset(20, 20));
      expect(controller.hasSelection, isTrue);

      final initialX = controller.selectedStrokes.first.points.first.dx;

      // Drag inside the selection box to move it by (+50, +50)
      final center = controller.selectionBounds!.center;
      controller.onPointerDown(center);
      controller.onPointerMove(center + const Offset(50, 50));
      controller.onPointerUp(center + const Offset(50, 50));

      expect(
        controller.selectedStrokes.first.points.first.dx,
        closeTo(initialX + 50.0, 0.01),
      );
      expect(controller.canUndo, isTrue);

      // Undo restores the stroke's initial position
      controller.undo();
      expect(controller.strokes.first.points.first.dx, closeTo(initialX, 0.01));

      // Redo moves it back
      controller.redo();
      expect(
        controller.strokes.first.points.first.dx,
        closeTo(initialX + 50.0, 0.01),
      );
    });

    test('Lasso duplicate, delete, and recolor actions work with undo', () {
      final stroke = Stroke(
        points: const [StrokePoint(50, 50), StrokePoint(60, 60)],
        color: Colors.black,
      );
      controller.loadStrokes([stroke], clearHistory: true);
      controller.setTool(ToolType.lasso);

      // Select stroke
      controller.onPointerDown(const Offset(20, 20));
      controller.onPointerMove(const Offset(100, 20));
      controller.onPointerMove(const Offset(100, 100));
      controller.onPointerUp(const Offset(20, 20));
      expect(controller.hasSelection, isTrue);

      // 1. Recolor
      controller.setColor(Colors.red);
      expect(controller.selectedStrokes.first.color, Colors.red);
      expect(controller.strokes.first.color, Colors.red);

      // 2. Duplicate
      controller.duplicateSelection();
      expect(controller.strokes.length, 2);
      expect(controller.hasSelection, isTrue);

      // 3. Delete
      controller.deleteSelection();
      expect(controller.strokes.length, 1);
      expect(controller.hasSelection, isFalse);

      // Undo brings back duplicated stroke
      controller.undo();
      expect(controller.strokes.length, 2);

      // Undo brings back original black color
      controller.undo(); // undo duplicate
      controller.undo(); // undo recolor
      expect(controller.strokes.first.color, Colors.black);
    });

    test('Single tap in lasso mode selects ONLY the topmost visible stroke', () {
      final bottomStroke = Stroke(
        points: const [StrokePoint(50, 50), StrokePoint(150, 50)],
        strokeWidth: 6.0,
      );
      final topStroke = Stroke(
        points: const [StrokePoint(100, 20), StrokePoint(100, 120)],
        strokeWidth: 6.0,
      );
      controller.loadStrokes([bottomStroke, topStroke], clearHistory: true);
      controller.setTool(ToolType.lasso);

      // Single tap directly on the intersection point (100, 50)
      controller.onPointerDown(const Offset(100, 50));
      controller.onPointerUp(const Offset(100, 50));

      // Should select ONLY the topStroke!
      expect(controller.hasSelection, isTrue);
      expect(controller.selectedStrokes.length, 1);
      expect(controller.selectedStrokes.first, topStroke);

      // Single tap on empty canvas at (300, 300) deselects
      controller.onPointerDown(const Offset(300, 300));
      controller.onPointerUp(const Offset(300, 300));
      expect(controller.hasSelection, isFalse);

      // Single tap on the exposed section of bottomStroke (60, 50) selects bottomStroke
      controller.onPointerDown(const Offset(60, 50));
      controller.onPointerUp(const Offset(60, 50));
      expect(controller.hasSelection, isTrue);
      expect(controller.selectedStrokes.length, 1);
      expect(controller.selectedStrokes.first, bottomStroke);
    });

    test('Duplicate places new stroke with non-overlapping smart offset', () {
      final stroke = Stroke(
        points: const [StrokePoint(100, 100), StrokePoint(150, 150)],
        strokeWidth: 4.0,
      );
      controller.loadStrokes([stroke], clearHistory: true);
      controller.setTool(ToolType.lasso);

      // Select stroke via single tap
      controller.onPointerDown(const Offset(125, 125));
      controller.onPointerUp(const Offset(125, 125));
      expect(controller.hasSelection, isTrue);

      final originalBounds = controller.selectionBounds!;

      // Duplicate
      controller.duplicateSelection();
      expect(controller.strokes.length, 2);
      expect(controller.hasSelection, isTrue);

      final duplicateBounds = controller.selectionBounds!;

      // The duplicate bounds should NOT overlap the original bounds horizontally
      expect(duplicateBounds.left, greaterThanOrEqualTo(originalBounds.right));

      // Single tap on the duplicate selects ONLY the duplicate
      final dupCenter = duplicateBounds.center;
      controller.onPointerDown(dupCenter);
      controller.onPointerUp(dupCenter);
      expect(controller.selectedStrokes.first, controller.strokes.last);

      // Single tap on original selects ONLY the original
      final origCenter = originalBounds.center;
      controller.onPointerDown(origCenter);
      controller.onPointerUp(origCenter);
      expect(controller.selectedStrokes.first, controller.strokes.first);
    });

    test('Duplicating a broken line sliced by area eraser', () {
      controller.setTool(ToolType.pen);
      controller.onPointerDown(const Offset(50, 100));
      controller.onPointerMove(const Offset(150, 100));
      controller.onPointerMove(const Offset(250, 100));
      controller.onPointerUp(const Offset(350, 100));
      expect(controller.strokes.length, 1);

      // Erase middle
      controller.setTool(ToolType.areaEraser);
      controller.setEraserRadius(20.0);
      controller.onPointerDown(const Offset(200, 100));
      controller.onPointerMove(const Offset(200, 100));
      controller.onPointerUp(const Offset(200, 100));
      expect(controller.strokes.length, 2);

      // Lasso tool
      controller.setTool(ToolType.lasso);

      // Circle both pieces of broken line
      controller.onPointerDown(const Offset(30, 80));
      controller.onPointerMove(const Offset(370, 80));
      controller.onPointerMove(const Offset(370, 120));
      controller.onPointerMove(const Offset(30, 120));
      controller.onPointerUp(const Offset(30, 80));

      expect(controller.hasSelection, isTrue);
      expect(controller.selectedStrokes.length, 2);

      final origBounds = controller.selectionBounds!;
      controller.duplicateSelection();

      expect(controller.strokes.length, 4);
      final dupBounds = controller.selectionBounds!;
      // For a horizontal broken line, duplicate is cleanly positioned parallel below it within page bounds
      expect(dupBounds.top, greaterThanOrEqualTo(origBounds.bottom));
      expect(dupBounds.right, lessThanOrEqualTo(AppConstants.defaultPageSize.width));
    });

    test('Tapping floating toolbar area does not disrupt selection even if another stroke is beneath it', () {
      final backgroundStroke = Stroke(
        points: const [StrokePoint(50, 100), StrokePoint(250, 100)],
        strokeWidth: 4.0,
      );
      final shapeToSelect = Stroke(
        points: const [StrokePoint(100, 160), StrokePoint(200, 160)],
        strokeWidth: 4.0,
      );
      controller.loadStrokes([backgroundStroke, shapeToSelect], clearHistory: true);
      controller.setTool(ToolType.lasso);

      // 1. Tap on shapeToSelect at (150, 160)
      controller.onPointerDown(const Offset(150, 160));
      controller.onPointerUp(const Offset(150, 160));
      expect(controller.hasSelection, isTrue);
      expect(controller.selectedStrokes.first, shapeToSelect);

      // The toolbar is positioned above the shape (around y = 160 - 56 = 104)
      final toolbarRect = SelectionToolbar.getToolbarRect(
        controller.selectionBounds!,
        pageWidth: AppConstants.defaultPageSize.width,
      );
      // Notice backgroundStroke passes right through y = 100, inside toolbarRect!
      final tapOnToolbar = toolbarRect.center;

      // 2. Tap on the toolbar (e.g. clicking Delete button)
      controller.onPointerDown(tapOnToolbar);
      controller.onPointerUp(tapOnToolbar);

      // Selection must remain on shapeToSelect! It must NOT switch to backgroundStroke or deselect!
      expect(controller.hasSelection, isTrue);
      expect(controller.selectedStrokes.first, shapeToSelect);

      // 3. Delete selection deletes shapeToSelect, NOT backgroundStroke!
      controller.deleteSelection();
      expect(controller.strokes.length, 1);
      expect(controller.strokes.first, backgroundStroke);
    });

    test('rotateSelection90 rotates selected strokes 90 degrees with undo and redo', () {
      final verticalLine = Stroke(
        points: const [
          StrokePoint(100, 50),
          StrokePoint(100, 150),
        ],
        strokeWidth: 4.0,
      );
      controller.loadStrokes([verticalLine], clearHistory: true);
      controller.setTool(ToolType.lasso);

      // Select line via tap
      controller.onPointerDown(const Offset(100, 100));
      controller.onPointerUp(const Offset(100, 100));
      expect(controller.hasSelection, isTrue);

      final origFirstPoint = controller.selectedStrokes.first.points.first;
      expect(origFirstPoint.dx, 100.0);
      expect(origFirstPoint.dy, 50.0);

      // Rotate 90 degrees clockwise around center (100, 100)
      controller.rotateSelection90(clockwise: true);
      expect(controller.selectionRotation, closeTo(pi / 2, 0.001));

      // (100, 50) rotated 90 deg clockwise around (100, 100) -> (150, 100)
      // (100, 150) rotated 90 deg clockwise around (100, 100) -> (50, 100)
      final rotatedStroke = controller.selectedStrokes.first;
      expect(rotatedStroke.points.first.dx, closeTo(150.0, 0.01));
      expect(rotatedStroke.points.first.dy, closeTo(100.0, 0.01));
      expect(rotatedStroke.points.last.dx, closeTo(50.0, 0.01));
      expect(rotatedStroke.points.last.dy, closeTo(100.0, 0.01));
      expect(controller.canUndo, isTrue);

      // Deselect resets rotation to 0
      controller.deselect();
      expect(controller.selectionRotation, 0.0);

      // Undo restores vertical orientation
      controller.undo();
      expect(controller.strokes.first.points.first.dx, closeTo(100.0, 0.01));
      expect(controller.strokes.first.points.first.dy, closeTo(50.0, 0.01));

      // Redo restores rotated horizontal orientation
      controller.redo();
      expect(controller.strokes.first.points.first.dx, closeTo(150.0, 0.01));
      expect(controller.strokes.first.points.first.dy, closeTo(100.0, 0.01));
    });

    test('Dragging rotation handle rotates strokes interactively and commits undo history', () {
      final verticalLine = Stroke(
        points: const [
          StrokePoint(100, 50),
          StrokePoint(100, 150),
        ],
        strokeWidth: 4.0,
      );
      controller.loadStrokes([verticalLine], clearHistory: true);
      controller.setTool(ToolType.lasso);

      // Select line via tap
      controller.onPointerDown(const Offset(100, 100));
      controller.onPointerUp(const Offset(100, 100));
      expect(controller.hasSelection, isTrue);

      final bounds = controller.selectionBounds!;
      final rotateHandlePos = LassoService.getRotationHandlePosition(bounds);

      // Drag rotation knob from (center.dx, bounds.top - 26) to the right (90 degree turn)
      controller.onPointerDown(rotateHandlePos);

      // Center is (100, 100). Top handle is at (100, 42 - 26 = 16) -> angle is -pi/2 (-90 deg)
      // Dragging to (184, 100) -> angle is 0 deg (relative delta +90 deg clockwise)
      controller.onPointerMove(const Offset(184, 100));
      expect(controller.selectionRotation, closeTo(pi / 2, 0.1));
      controller.onPointerUp(const Offset(184, 100));

      // Points should now be rotated by ~90 degrees
      expect(controller.selectedStrokes.first.points.first.dx, closeTo(150.0, 1.0));
      expect(controller.selectedStrokes.first.points.first.dy, closeTo(100.0, 1.0));
      expect(controller.canUndo, isTrue);

      // Undo restores original orientation
      controller.undo();
      expect(controller.strokes.first.points.first.dx, closeTo(100.0, 0.01));
      expect(controller.strokes.first.points.first.dy, closeTo(50.0, 0.01));
    });
  });

  group('EraserService Tests', () {

    test('Broad phase rejects points far away', () {
      final stroke = Stroke(
        points: const [StrokePoint(0, 0), StrokePoint(10, 10)],
      );
      final hit = EraserService.hitTestStroke(
        stroke,
        const Offset(500, 500),
        10.0,
      );
      expect(hit, isFalse);
    });

    test('Narrow phase hits point on line segment', () {
      final stroke = Stroke(
        points: const [StrokePoint(0, 0), StrokePoint(0, 100)],
      );
      final hit = EraserService.hitTestStroke(
        stroke,
        const Offset(2, 50),
        5.0,
      );
      expect(hit, isTrue);
    });

    test('sliceStroke splits a line into two pieces when erased in the middle', () {
      final stroke = Stroke(
        points: const [
          StrokePoint(0, 0),
          StrokePoint(100, 0),
        ],
      );

      // Erase at center (50, 0) with radius 10
      final fragments = EraserService.sliceStroke(
        stroke,
        const Offset(50, 0),
        10.0,
      );

      expect(fragments.length, 2);
      // Fragment 1: 0 to 40
      expect(fragments[0].points.first.dx, 0.0);
      expect(fragments[0].points.last.dx, closeTo(40.0, 0.01));

      // Fragment 2: 60 to 100
      expect(fragments[1].points.first.dx, closeTo(60.0, 0.01));
      expect(fragments[1].points.last.dx, 100.0);
    });

    test('sliceStroke clips the end of a line when touched', () {
      final stroke = Stroke(
        points: const [
          StrokePoint(0, 0),
          StrokePoint(100, 0),
        ],
      );

      // Erase at (95, 0) with radius 10 -> clips 85..100
      final fragments = EraserService.sliceStroke(
        stroke,
        const Offset(95, 0),
        10.0,
      );

      expect(fragments.length, 1);
      expect(fragments.first.points.first.dx, 0.0);
      expect(fragments.first.points.last.dx, closeTo(85.0, 0.01));
    });

    test('sliceStroke completely removes a stroke fully enclosed by eraser', () {
      final stroke = Stroke(
        points: const [
          StrokePoint(10, 10),
          StrokePoint(20, 20),
        ],
      );

      // Erase at (15, 15) with huge radius 50 -> fully erased
      final fragments = EraserService.sliceStroke(
        stroke,
        const Offset(15, 15),
        50.0,
      );

      expect(fragments, isEmpty);
    });

    test('sliceStroke leaves stroke untouched when missing', () {
      final stroke = Stroke(
        points: const [
          StrokePoint(0, 0),
          StrokePoint(100, 0),
        ],
      );

      final fragments = EraserService.sliceStroke(
        stroke,
        const Offset(50, 50),
        10.0,
      );

      expect(fragments.length, 1);
      expect(identical(fragments.first, stroke), isTrue);
    });
  });
}
