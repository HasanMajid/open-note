import 'dart:math';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_note/features/canvas/controllers/canvas_controller.dart';
import 'package:open_note/features/canvas/models/stroke.dart';
import 'package:open_note/features/canvas/models/stroke_point.dart';
import 'package:open_note/features/canvas/models/tool_type.dart';
import 'package:open_note/features/canvas/presentation/note_canvas.dart';
import 'package:open_note/features/canvas/presentation/widgets/selection_toolbar.dart';

void main() {
  testWidgets('NoteCanvas does not overflow in viewport smaller than page height',
      (tester) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final controller = CanvasController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteCanvas(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('NoteCanvas handles multiple pages without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final controller = CanvasController();
    controller.addPage();
    controller.addPage(); // 3 pages total
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteCanvas(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('NoteCanvas handles gestures far outside pages into pasteboard without dead zones',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final controller = CanvasController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteCanvas(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Draw a stroke that extends far into the left pasteboard (x = 50 on screen which is negative in scene)
    final gesture = await tester.startGesture(const Offset(50, 200));
    await gesture.moveBy(const Offset(30, 30));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(controller.pages[0].strokes.length, equals(1));
    expect(controller.pages[0].strokes.first.points.isNotEmpty, isTrue);

    // 2. Select the stroke with lasso
    controller.setTool(ToolType.lasso);
    final strokePt = controller.pages[0].strokes.first.points.first;
    // Single tap on stroke
    controller.onPointerDown(Offset(strokePt.dx, strokePt.dy));
    controller.onPointerUp(Offset(strokePt.dx, strokePt.dy));
    await tester.pumpAndSettle();

    expect(controller.hasSelection, isTrue);
  });

  testWidgets('Mouse scroll without Ctrl only scrolls and does not zoom', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final controller = CanvasController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteCanvas(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final initialMatrix = iv.transformationController!.value.clone();
    final initialScale = initialMatrix.getMaxScaleOnAxis();

    // Send mouse scroll event downwards (scrollDelta.dy = 100)
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(500, 400),
        scrollDelta: Offset(0, 100),
      ),
    );
    await tester.pumpAndSettle();

    final afterMatrix = iv.transformationController!.value.clone();
    final afterScale = afterMatrix.getMaxScaleOnAxis();

    // Scale must remain exactly the same (no zoom!)
    expect(afterScale, equals(initialScale));
    // Y translation must have scrolled by -100
    expect(afterMatrix.storage[13], equals(initialMatrix.storage[13] - 100));
  });

  testWidgets('Mouse scroll with Ctrl zooms in and out', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final controller = CanvasController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteCanvas(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final initialScale = iv.transformationController!.value.getMaxScaleOnAxis();

    // Press Control key down
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    // Scroll up with Ctrl (scrollDelta.dy = -100) -> Zoom In
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(500, 400),
        scrollDelta: Offset(0, -100),
      ),
    );
    await tester.pumpAndSettle();

    final zoomedInScale = iv.transformationController!.value.getMaxScaleOnAxis();
    expect(zoomedInScale, greaterThan(initialScale));

    // Release Control key
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  });

  testWidgets('PointerScaleEvent triggers zoom (web & trackpad pinch/ctrl+wheel signal)', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final controller = CanvasController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteCanvas(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final initialScale = iv.transformationController!.value.getMaxScaleOnAxis();

    // Send PointerScaleEvent with scale = 1.25 (zoom in)
    await tester.sendEventToBinding(
      const PointerScaleEvent(
        position: Offset(500, 400),
        scale: 1.25,
      ),
    );
    await tester.pumpAndSettle();

    final zoomedInScale = iv.transformationController!.value.getMaxScaleOnAxis();
    expect(zoomedInScale, greaterThan(initialScale));
  });

  testWidgets('Top and horizontal boundaries clamp canvas scrolling', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final controller = CanvasController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteCanvas(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));

    // Try to scroll UP past the top of Page 1 (scrollDelta.dy = -1000)
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(500, 400),
        scrollDelta: Offset(0, -1000),
      ),
    );
    await tester.pumpAndSettle();

    // Top boundary constraint: ty cannot exceed 40.0
    expect(iv.transformationController!.value.storage[13], lessThanOrEqualTo(40.0));

    // Try to scroll far left (scrollDelta.dx = -2000)
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(500, 400),
        scrollDelta: Offset(-2000, 0),
      ),
    );
    await tester.pumpAndSettle();

    // Horizontal pasteboard margin constraint: tx cannot exceed centerX + 450
    // At scale 1.0 on 1000px width: centerX = (1000 - 600)/2 = 200. Max tx = 650.
    expect(iv.transformationController!.value.storage[12], lessThanOrEqualTo(650.0));
  });

  testWidgets('Live Zoom percentage displays, zooms out to 50% limit, and resets', (tester) async {
    tester.view.physicalSize = const Size(1920, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final controller = CanvasController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteCanvas(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Check initial zoom % is 100% and fit/reset view button is present
    expect(find.text('100%'), findsOneWidget);
    expect(find.byKey(const Key('reset_view_button')), findsOneWidget);

    // Tap Zoom In (+)
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    // Zoom % pill should now show 120%
    expect(find.text('120%'), findsOneWidget);

    // Tap the percentage button to reset zoom in-place
    await tester.tap(find.byKey(const Key('zoom_percentage_button')));
    await tester.pumpAndSettle();

    // Zoom % pill should be back to 100%
    expect(find.text('100%'), findsOneWidget);

    // Tap Zoom Out (-) multiple times to verify zoom out works and limits at 50%
    await tester.tap(find.byIcon(Icons.remove));
    await tester.pumpAndSettle();
    expect(find.text('83%'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.remove));
    await tester.pumpAndSettle();
    expect(find.text('69%'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.remove));
    await tester.pumpAndSettle();
    expect(find.text('58%'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.remove));
    await tester.pumpAndSettle();
    // Clamped strictly at 50% minimum zoom limit
    expect(find.text('50%'), findsOneWidget);

    // Tap Reset View button (fit screen)
    await tester.tap(find.byKey(const Key('reset_view_button')));
    await tester.pumpAndSettle();

    // Reset view should return to 100%
    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('Off-screen page indicator appears when page is out of view and jumps back when tapped', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final controller = CanvasController();
    controller.addPage(); // 2 pages total
    controller.setActivePage(0); // Page 1 is active
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteCanvas(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Active page is 0 (Page 1), initially on screen
    expect(find.byKey(const Key('back_to_page_indicator')), findsNothing);

    // Scroll down by 1000px so Page 1 is pushed above the viewport
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(500, 400),
        scrollDelta: Offset(0, 1000),
      ),
    );
    await tester.pumpAndSettle();

    // Off-screen indicator should now appear showing Page 1
    expect(find.byKey(const Key('back_to_page_indicator')), findsOneWidget);
    expect(find.text('Page 1'), findsWidgets);

    // Tap the indicator to jump back to Page 1
    await tester.tap(find.byKey(const Key('back_to_page_indicator')));
    await tester.pumpAndSettle();

    // Page 1 is back in view, indicator should disappear
    expect(find.byKey(const Key('back_to_page_indicator')), findsNothing);
  });

  testWidgets('Mobile viewport fits page width at 100% on initial load and Reset View', (tester) async {
    // 390x844 (standard mobile phone viewport like iPhone 13/14)
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final controller = CanvasController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteCanvas(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The zoom percentage should be 100%
    expect(find.text('100%'), findsOneWidget);

    final iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final matrix = iv.transformationController!.value;
    final sx = matrix.storage[0];
    final sy = matrix.storage[1];
    final scale = sqrt(sx * sx + sy * sy);

    // Expected baseScale: 390 / 600 = 0.65
    // Page width on screen = 600 * 0.65 = 390px, completely filling screen width
    expect(scale, closeTo(0.65, 0.01));
    expect(matrix.storage[12], closeTo(0.0, 0.5)); // Page left edge starts at x = 0

    // Zoom in with (+) button
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('120%'), findsOneWidget);

    // Tap Reset View button (fit screen)
    await tester.tap(find.byKey(const Key('reset_view_button')));
    await tester.pumpAndSettle();

    // Should return to 100% scale and fill screen width
    expect(find.text('100%'), findsOneWidget);
    final resetMatrix = iv.transformationController!.value;
    final resetScale = sqrt(resetMatrix.storage[0] * resetMatrix.storage[0] + resetMatrix.storage[1] * resetMatrix.storage[1]);
    expect(resetScale, closeTo(0.65, 0.01));
    expect(resetMatrix.storage[12], closeTo(0.0, 0.5));
  });

  testWidgets('Two-finger touch pinch-to-zoom scales canvas without leaving stray strokes', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final controller = CanvasController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteCanvas(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final initialScale = iv.transformationController!.value.storage[0];

    // Place finger 1 down at (150, 400)
    final finger1 = await tester.startGesture(const Offset(150, 400), pointer: 1, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 20));

    // Place finger 2 down at (250, 400)
    final finger2 = await tester.startGesture(const Offset(250, 400), pointer: 2, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 20));

    // Pinch apart to zoom in (finger 1 moves to 100, finger 2 moves to 300)
    await finger1.moveTo(const Offset(100, 400));
    await finger2.moveTo(const Offset(300, 400));
    await tester.pump(const Duration(milliseconds: 20));

    // Release fingers
    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();

    final finalScale = iv.transformationController!.value.storage[0];

    // Scale should have increased due to pinch out
    expect(finalScale, greaterThan(initialScale));

    // No accidental stroke should have been drawn from finger 1 or finger 2
    expect(controller.pages[0].strokes, isEmpty);
  });

  testWidgets('Stylus drawing palm rejection ignores touch pointer during active inking', (tester) async {
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final controller = CanvasController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteCanvas(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Stylus drawing down
    final stylus = await tester.startGesture(const Offset(300, 200), pointer: 1, kind: PointerDeviceKind.stylus);
    await tester.pump(const Duration(milliseconds: 20));
    await stylus.moveBy(const Offset(50, 50));
    await tester.pump(const Duration(milliseconds: 20));

    // Palm rests on screen (touch event)
    final palm = await tester.startGesture(const Offset(450, 350), pointer: 2, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 20));

    // Stylus continues drawing
    await stylus.moveBy(const Offset(50, 50));
    await tester.pump(const Duration(milliseconds: 20));

    await stylus.up();
    await palm.up();
    await tester.pumpAndSettle();

    // Stylus stroke was completed successfully
    expect(controller.pages[0].strokes.length, equals(1));
    expect(controller.pages[0].strokes.first.points.length, greaterThan(1));
  });

  testWidgets('Floating selection toolbar works when content is moved outside the page into pasteboard', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final controller = CanvasController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteCanvas(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Draw a stroke that lives far out in the left pasteboard (outside page bounds, x = -100)
    final strokeInPasteboard = Stroke(
      points: const [StrokePoint(-120, 100), StrokePoint(-50, 100)],
      strokeWidth: 4.0,
    );
    controller.loadStrokes([strokeInPasteboard], clearHistory: true);
    controller.setTool(ToolType.lasso);

    // 2. Select it with lasso
    controller.onPointerDown(const Offset(-85, 100));
    controller.onPointerUp(const Offset(-85, 100));
    await tester.pumpAndSettle();

    expect(controller.hasSelection, isTrue);
    expect(controller.selectedStrokes.first, strokeInPasteboard);
    expect(controller.selectionBounds!.center.dx, lessThan(0.0)); // Outside page in pasteboard!

    // The floating selection toolbar should be visible
    expect(find.byType(SelectionToolbar), findsOneWidget);
    final dupBtn = find.descendant(of: find.byType(SelectionToolbar), matching: find.byIcon(Icons.copy_rounded));
    expect(dupBtn, findsOneWidget);

    // 3. Tap the Duplicate button on the toolbar
    await tester.tap(dupBtn);
    await tester.pumpAndSettle();

    // Duplicate should have created a second stroke in the pasteboard!
    expect(controller.strokes.length, 2);
    expect(controller.hasSelection, isTrue);

    // 4. Tap the Rotate 90° button on the toolbar
    final rotateBtn = find.descendant(of: find.byType(SelectionToolbar), matching: find.byIcon(Icons.rotate_right_rounded));
    await tester.tap(rotateBtn);
    await tester.pumpAndSettle();
    expect(controller.selectionRotation, closeTo(pi / 2, 0.01));

    // 5. Tap the Delete button on the toolbar
    final deleteBtn = find.descendant(of: find.byType(SelectionToolbar), matching: find.byIcon(Icons.delete_outline_rounded));
    await tester.tap(deleteBtn);
    await tester.pumpAndSettle();
    expect(controller.strokes.length, 1);
    expect(controller.hasSelection, isFalse);
  });

  testWidgets('Pinching inward past minScale clamps scale cleanly without translation drift or bouncing', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final controller = CanvasController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteCanvas(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final tc = iv.transformationController!;

    // First zoom out to 50% (minScale) using zoom-out button
    for (int i = 0; i < 5; i++) {
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pumpAndSettle();
    }
    expect(find.text('50%'), findsOneWidget);

    final currentIv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final scaleAtMin = currentIv.transformationController!.value.storage[0];
    expect(scaleAtMin, closeTo(0.5, 0.01));
    final txAtMin = tc.value.storage[12];
    final tyAtMin = tc.value.storage[13];

    // Now simulate two fingers pinching inward past minScale (from 200px apart to 60px apart)
    final finger1 = await tester.startGesture(const Offset(400, 400), pointer: 10);
    final finger2 = await tester.startGesture(const Offset(600, 400), pointer: 11);
    await tester.pump();

    // Move fingers inward
    await finger1.moveTo(const Offset(470, 400));
    await finger2.moveTo(const Offset(530, 400));
    await tester.pump();

    // Scale should still be clamped at minScale (0.5)
    final scaleAfterPinch = currentIv.transformationController!.value.storage[0];
    expect(scaleAfterPinch, closeTo(0.5, 0.01));

    // Translation should NOT jump, pan or bounce around
    final txAfterPinch = currentIv.transformationController!.value.storage[12];
    final tyAfterPinch = currentIv.transformationController!.value.storage[13];
    expect((txAfterPinch - txAtMin).abs(), lessThan(5.0));
    expect((tyAfterPinch - tyAtMin).abs(), lessThan(5.0));

    await finger1.up();
    await finger2.up();
    await tester.pumpAndSettle();
  });
}

