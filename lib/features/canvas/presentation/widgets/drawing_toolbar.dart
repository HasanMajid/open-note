import 'package:flutter/material.dart';
import 'package:open_note/core/theme/app_colors.dart';
import 'package:open_note/features/canvas/controllers/canvas_controller.dart';
import 'package:open_note/features/canvas/models/rich_text_span.dart';
import 'package:open_note/features/canvas/models/tool_type.dart';
import 'package:open_note/features/canvas/presentation/widgets/custom_color_picker_dialog.dart';
import 'package:open_note/features/canvas/presentation/widgets/eraser_radius_picker.dart';
import 'package:open_note/features/canvas/presentation/widgets/stroke_width_picker.dart';
import 'package:open_note/features/canvas/presentation/widgets/tool_icon.dart';

class DrawingToolbar extends StatelessWidget {
  final CanvasController controller;

  static const List<double> _standardFontSizes = [
    10.0,
    12.0,
    14.0,
    15.0,
    16.0,
    18.0,
    20.0,
    24.0,
    28.0,
    32.0,
    40.0,
    48.0,
    64.0,
  ];

  const DrawingToolbar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final activeTool = controller.activeTool;
        final isDrawing = activeTool.isDrawingTool;
        final currentPalette = activeTool == ToolType.highlighter
            ? AppColors.highlighterPalette
            : AppColors.penPalette;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
          decoration: BoxDecoration(
            color: controller.isDarkMode ? AppColors.toolbarDark : Colors.white,
            boxShadow: const [
              BoxShadow(
                color: Color(0x1F000000),
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Tool Selector (Segmented)
                SegmentedButton<ToolType>(
                  style: SegmentedButton.styleFrom(
                    backgroundColor: controller.isDarkMode
                        ? const Color(0xFF2C2C36)
                        : Colors.grey.shade100,
                    foregroundColor: controller.isDarkMode
                        ? Colors.white70
                        : Colors.black87,
                    selectedForegroundColor: Colors.white,
                    selectedBackgroundColor: AppColors.primary,
                    side: BorderSide(
                      color: controller.isDarkMode
                          ? const Color(0xFF444455)
                          : Colors.grey.shade300,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  segments: ToolType.values.map((tool) {
                    return ButtonSegment<ToolType>(
                      value: tool,
                      icon: ToolIcon(
                        tool: tool,
                        size: 20,
                        isSelected: activeTool == tool,
                        isDarkMode: controller.isDarkMode,
                      ),
                      tooltip: tool.label,
                    );
                  }).toList(),
                  selected: {activeTool},
                  onSelectionChanged: (newSelection) {
                    controller.setTool(newSelection.first);
                  },
                  showSelectedIcon: false,
                ),

                const SizedBox(width: 12),
                VerticalDivider(
                  width: 1,
                  indent: 8,
                  endIndent: 8,
                  color: controller.isDarkMode
                      ? const Color(0xFF444455)
                      : Colors.grey.shade300,
                ),
                const SizedBox(width: 12),

                // Stroke Width Button (only shown for drawing tools)
                if (isDrawing) ...[
                  Tooltip(
                    message: 'Stroke Thickness',
                    child: InkWell(
                      onTap: () => StrokeWidthPicker.show(context, controller),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: controller.isDarkMode
                              ? const Color(0xFF2C2C36)
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: controller.isDarkMode
                                ? const Color(0xFF444455)
                                : Colors.grey.shade300,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 16,
                              height: 16,
                              alignment: Alignment.center,
                              child: Container(
                                width: controller.strokeWidth.clamp(3.0, 16.0),
                                height: controller.strokeWidth.clamp(3.0, 16.0),
                                decoration: BoxDecoration(
                                  color: controller.getDisplayStrokeColor(
                                    controller.activeColor,
                                  ),
                                  shape: activeTool == ToolType.highlighter
                                      ? BoxShape.rectangle
                                      : BoxShape.circle,
                                  borderRadius:
                                      activeTool == ToolType.highlighter
                                          ? BorderRadius.circular(2)
                                          : null,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${controller.strokeWidth.toInt()}pt',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: controller.isDarkMode
                                    ? Colors.white
                                    : Colors.black87,
                              ),
                            ),
                            Icon(
                              Icons.arrow_drop_down,
                              size: 18,
                              color: controller.isDarkMode
                                  ? Colors.white70
                                  : Colors.black87,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  VerticalDivider(
                    width: 1,
                    indent: 8,
                    endIndent: 8,
                    color: controller.isDarkMode
                        ? const Color(0xFF444455)
                        : Colors.grey.shade300,
                  ),
                  const SizedBox(width: 12),
                ],

                // Eraser Settings Button (only shown for eraser tools)
                if (activeTool.isEraser) ...[
                  Tooltip(
                    message: 'Eraser Size & Mode',
                    child: InkWell(
                      onTap: () => EraserRadiusPicker.show(context, controller),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: controller.isDarkMode
                              ? const Color(0xFF2C2C36)
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: controller.isDarkMode
                                ? const Color(0xFF444455)
                                : Colors.grey.shade300,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ToolIcon(
                              tool: activeTool,
                              size: 18,
                              isSelected: false,
                              isDarkMode: controller.isDarkMode,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${controller.eraserRadius.toInt()}pt',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: controller.isDarkMode
                                    ? Colors.white
                                    : Colors.black87,
                              ),
                            ),
                            Icon(
                              Icons.arrow_drop_down,
                              size: 18,
                              color: controller.isDarkMode
                                  ? Colors.white70
                                  : Colors.black87,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  VerticalDivider(
                    width: 1,
                    indent: 8,
                    endIndent: 8,
                    color: controller.isDarkMode
                        ? const Color(0xFF444455)
                        : Colors.grey.shade300,
                  ),
                  const SizedBox(width: 12),
                ],

                // Lasso Selection Controls
                if (activeTool == ToolType.lasso) ...[
                  if (controller.hasSelection) ...[
                    Tooltip(
                      message: 'Duplicate Selection',
                      child: IconButton(
                        icon: Icon(
                          Icons.copy_rounded,
                          size: 20,
                          color: controller.isDarkMode
                              ? Colors.white70
                              : Colors.black87,
                        ),
                        onPressed: controller.duplicateSelection,
                      ),
                    ),
                    Tooltip(
                      message: 'Delete Selection',
                      child: IconButton(
                        icon: Icon(
                          Icons.delete_outline_rounded,
                          size: 20,
                          color: Colors.red.shade400,
                        ),
                        onPressed: controller.deleteSelection,
                      ),
                    ),
                    Tooltip(
                      message: 'Deselect',
                      child: IconButton(
                        icon: Icon(
                          Icons.close_rounded,
                          size: 20,
                          color: controller.isDarkMode
                              ? Colors.white70
                              : Colors.black87,
                        ),
                        onPressed: controller.deselect,
                      ),
                    ),
                    const SizedBox(width: 8),
                    VerticalDivider(
                      width: 1,
                      indent: 8,
                      endIndent: 8,
                      color: controller.isDarkMode
                          ? const Color(0xFF444455)
                          : Colors.grey.shade300,
                    ),
                    const SizedBox(width: 8),
                  ] else ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: controller.isDarkMode
                            ? const Color(0xFF1E2838)
                            : Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: controller.isDarkMode
                              ? const Color(0xFF2E4568)
                              : Colors.blue.shade200,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.touch_app_outlined,
                            size: 16,
                            color: controller.isDarkMode
                                ? const Color(0xFF90CAF9)
                                : Colors.blue.shade700,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Tap or circle strokes to select',
                            style: TextStyle(
                              fontSize: 12,
                              color: controller.isDarkMode
                                  ? const Color(0xFF90CAF9)
                                  : Colors.blue.shade800,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    VerticalDivider(
                      width: 1,
                      indent: 8,
                      endIndent: 8,
                      color: controller.isDarkMode
                          ? const Color(0xFF444455)
                          : Colors.grey.shade300,
                    ),
                    const SizedBox(width: 12),
                  ],
                ],

                // Text Tool Formatting Bar (docked in top toolbar)
                if (activeTool == ToolType.text) ...[
                  // 1. Heading Selector Dropdown
                  _buildHeadingDropdown(context),

                  const SizedBox(width: 8),

                  // 1.5. Font Size Selector & Stepper
                  _buildFontSizeControls(context),

                  const SizedBox(width: 8),

                  // 2. Inline Style Toggles: B, I, U, S
                  _buildFormatToggleBtn(
                    label: 'B',
                    tooltip: 'Bold',
                    isBold: true,
                    isActive: controller.activeTextBold,
                    onTap: controller.toggleBold,
                  ),
                  const SizedBox(width: 4),
                  _buildFormatToggleBtn(
                    label: 'I',
                    tooltip: 'Italic',
                    isItalic: true,
                    isActive: controller.activeTextItalic,
                    onTap: controller.toggleItalic,
                  ),
                  const SizedBox(width: 4),
                  _buildFormatToggleBtn(
                    label: 'U',
                    tooltip: 'Underline',
                    isUnderline: true,
                    isActive: controller.activeTextUnderline,
                    onTap: controller.toggleUnderline,
                  ),
                  const SizedBox(width: 4),
                  _buildFormatToggleBtn(
                    label: 'S',
                    tooltip: 'Strikethrough',
                    isStrikethrough: true,
                    isActive: controller.activeTextStrikethrough,
                    onTap: controller.toggleStrikethrough,
                  ),

                  // RTL / LTR Language Direction Toggle
                  const SizedBox(width: 4),
                  Tooltip(
                    message: controller.isCurrentTextRtl
                        ? 'Right-to-Left (RTL) active. Click to switch to LTR'
                        : 'Left-to-Right (LTR) active. Click to switch to RTL (Arabic, Hebrew)',
                    child: InkWell(
                      key: const Key('toggle_rtl_button'),
                      borderRadius: BorderRadius.circular(6),
                      onTap: controller.toggleTextDirection,
                      child: Container(
                        height: 30,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          color: controller.isCurrentTextRtl
                              ? const Color(0xFF007AFF).withValues(
                                  alpha: controller.isDarkMode ? 0.35 : 0.15,
                                )
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: controller.isCurrentTextRtl
                                ? const Color(0xFF007AFF)
                                : (controller.isDarkMode
                                    ? const Color(0xFF444455)
                                    : Colors.grey.shade300),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              controller.isCurrentTextRtl
                                  ? Icons.format_textdirection_r_to_l_rounded
                                  : Icons.format_textdirection_l_to_r_rounded,
                              size: 16,
                              color: controller.isCurrentTextRtl
                                  ? const Color(0xFF64B5F6)
                                  : (controller.isDarkMode
                                      ? Colors.white70
                                      : Colors.black87),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              controller.isCurrentTextRtl ? 'RTL' : 'LTR',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: controller.isCurrentTextRtl
                                    ? const Color(0xFF64B5F6)
                                    : (controller.isDarkMode
                                        ? Colors.white70
                                        : Colors.black87),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(width: 8),
                  VerticalDivider(
                    width: 1,
                    indent: 8,
                    endIndent: 8,
                    color: controller.isDarkMode
                        ? const Color(0xFF444455)
                        : Colors.grey.shade300,
                  ),
                  const SizedBox(width: 8),

                  // 3. Text Font Color Picker Menu
                  _buildTextColorMenu(context),

                  const SizedBox(width: 4),

                  // 4. Text Highlight Color Menu
                  _buildTextHighlightMenu(context),

                  const SizedBox(width: 8),
                  VerticalDivider(
                    width: 1,
                    indent: 8,
                    endIndent: 8,
                    color: controller.isDarkMode
                        ? const Color(0xFF444455)
                        : Colors.grey.shade300,
                  ),
                  const SizedBox(width: 8),

                  // 5. Spawn new text box button
                  Tooltip(
                    message: 'Add new text box',
                    child: OutlinedButton.icon(
                      icon: Icon(
                        Icons.add_rounded,
                        size: 18,
                        color: controller.isDarkMode
                            ? Colors.white
                            : Colors.black87,
                      ),
                      label: Text(
                        'Add Box',
                        style: TextStyle(
                          fontSize: 12,
                          color: controller.isDarkMode
                              ? Colors.white
                              : Colors.black87,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        visualDensity: VisualDensity.compact,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        side: BorderSide(
                          color: controller.isDarkMode
                              ? const Color(0xFF444455)
                              : Colors.grey.shade300,
                        ),
                      ),
                      onPressed: () {
                        controller.addTextBox(const Offset(80, 100));
                      },
                    ),
                  ),

                  // 6. Delete & Done buttons (if a text box is focused)
                  if (controller.activeTextBox != null) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'Delete text box',
                      child: IconButton(
                        icon: Icon(
                          Icons.delete_outline_rounded,
                          size: 20,
                          color: Colors.red.shade400,
                        ),
                        onPressed: controller.deleteActiveTextBox,
                      ),
                    ),
                    Tooltip(
                      message: 'Done / Deselect',
                      child: IconButton(
                        icon: Icon(
                          Icons.check_rounded,
                          size: 20,
                          color: controller.isDarkMode
                              ? const Color(0xFF64B5F6)
                              : const Color(0xFF007AFF),
                        ),
                        onPressed: controller.unfocusActiveTextBox,
                      ),
                    ),
                  ],

                  const SizedBox(width: 12),
                  VerticalDivider(
                    width: 1,
                    indent: 8,
                    endIndent: 8,
                    color: controller.isDarkMode
                        ? const Color(0xFF444455)
                        : Colors.grey.shade300,
                  ),
                  const SizedBox(width: 12),
                ],

                // Color Palette Dots & Custom Color Picker (for drawing and recoloring selection)
                if (isDrawing ||
                    (activeTool == ToolType.lasso &&
                        controller.hasSelection)) ...[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ...currentPalette.map((color) {
                        final isSelected =
                            controller.activeColor.toARGB32() == color.toARGB32();
                        final isNearBlack = CanvasController.isNearBlack(color);
                        return Tooltip(
                          message: isNearBlack && controller.isDarkMode
                              ? 'Black Ink (renders white in Dark Mode)'
                              : 'Ink Color',
                          child: GestureDetector(
                            onTap: () => controller.setColor(color),
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 3.0),
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: color,
                                shape: activeTool == ToolType.highlighter
                                    ? BoxShape.rectangle
                                    : BoxShape.circle,
                                borderRadius: activeTool == ToolType.highlighter
                                    ? BorderRadius.circular(4)
                                    : null,
                                border: Border.all(
                                  color: isSelected
                                      ? AppColors.primary
                                      : (controller.isDarkMode
                                          ? (isNearBlack
                                              ? Colors.grey.shade600
                                              : Colors.grey.shade700)
                                          : Colors.grey.shade400),
                                  width: isSelected ? 2.5 : 1.0,
                                ),
                              ),
                              child: isNearBlack && controller.isDarkMode
                                  ? Center(
                                      child: Container(
                                        width: 8,
                                        height: 8,
                                        decoration: const BoxDecoration(
                                          color: Colors.white,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                        );
                      }),

                      // Custom colors chosen by user
                      ...controller.customColors
                          .where((c) =>
                              !currentPalette.any((p) => p.toARGB32() == c.toARGB32()))
                          .map((color) {
                        final isSelected =
                            controller.activeColor.toARGB32() == color.toARGB32();
                        return GestureDetector(
                          onTap: () => controller.setColor(color),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3.0),
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: color,
                              shape: activeTool == ToolType.highlighter
                                  ? BoxShape.rectangle
                                  : BoxShape.circle,
                              borderRadius: activeTool == ToolType.highlighter
                                  ? BorderRadius.circular(4)
                                  : null,
                              border: Border.all(
                                color: isSelected
                                    ? AppColors.primary
                                    : Colors.grey.shade400,
                                width: isSelected ? 2.5 : 1.0,
                              ),
                            ),
                          ),
                        );
                      }),

                      // Custom Color Picker Button
                      Tooltip(
                        message: 'Custom Color',
                        child: InkWell(
                          onTap: () =>
                              CustomColorPickerDialog.show(context, controller),
                          borderRadius: BorderRadius.circular(13),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4.0),
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: controller.isDarkMode
                                  ? const Color(0xFF2C2C36)
                                  : Colors.grey.shade100,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: controller.isDarkMode
                                    ? const Color(0xFF444455)
                                    : Colors.grey.shade400,
                                width: 1.0,
                              ),
                            ),
                            child: Icon(
                              Icons.palette_outlined,
                              size: 15,
                              color: controller.isDarkMode
                                  ? Colors.white70
                                  : Colors.black87,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  VerticalDivider(
                    width: 1,
                    indent: 8,
                    endIndent: 8,
                    color: controller.isDarkMode
                        ? const Color(0xFF444455)
                        : Colors.grey.shade300,
                  ),
                  const SizedBox(width: 12),
                ],

                // Insert / Paste Image
                _buildImageMenuButton(context),

                const SizedBox(width: 8),
                VerticalDivider(
                  width: 1,
                  indent: 8,
                  endIndent: 8,
                  color: controller.isDarkMode
                      ? const Color(0xFF444455)
                      : Colors.grey.shade300,
                ),
                const SizedBox(width: 8),

                // Undo / Redo
                IconButton(
                  icon: Icon(
                    Icons.undo_rounded,
                    size: 20,
                    color: controller.canUndo
                        ? (controller.isDarkMode
                            ? Colors.white
                            : Colors.black87)
                        : (controller.isDarkMode
                            ? Colors.white24
                            : Colors.black26),
                  ),
                  tooltip: 'Undo',
                  onPressed: controller.canUndo ? controller.undo : null,
                ),
                IconButton(
                  icon: Icon(
                    Icons.redo_rounded,
                    size: 20,
                    color: controller.canRedo
                        ? (controller.isDarkMode
                            ? Colors.white
                            : Colors.black87)
                        : (controller.isDarkMode
                            ? Colors.white24
                            : Colors.black26),
                  ),
                  tooltip: 'Redo',
                  onPressed: controller.canRedo ? controller.redo : null,
                ),

                // Clear Page
                IconButton(
                  icon: Icon(
                    Icons.delete_outline,
                    size: 20,
                    color: controller.strokes.isNotEmpty
                        ? (controller.isDarkMode
                            ? Colors.white
                            : Colors.black87)
                        : (controller.isDarkMode
                            ? Colors.white24
                            : Colors.black26),
                  ),
                  tooltip: 'Clear Page',
                  onPressed: controller.strokes.isNotEmpty
                      ? () => _showClearDialog(context)
                      : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showClearDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Canvas?'),
        content: const Text('Are you sure you want to clear all strokes?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              controller.clear();
              Navigator.pop(ctx);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  Widget _buildHeadingDropdown(BuildContext context) {
    final currentHeading = controller.activeTextHeading;

    return PopupMenuButton<HeadingLevel>(
      tooltip: 'Heading style',
      initialValue: currentHeading,
      onSelected: controller.setHeading,
      color: controller.isDarkMode ? const Color(0xFF2C2C36) : Colors.white,
      padding: EdgeInsets.zero,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: controller.isDarkMode
              ? const Color(0xFF2C2C36)
              : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: controller.isDarkMode
                ? const Color(0xFF444455)
                : Colors.grey.shade300,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              currentHeading == HeadingLevel.none
                  ? 'Body'
                  : currentHeading.name.toUpperCase(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: controller.isDarkMode ? Colors.white : Colors.black87,
              ),
            ),
            Icon(
              Icons.arrow_drop_down,
              size: 16,
              color: controller.isDarkMode ? Colors.white70 : Colors.black87,
            ),
          ],
        ),
      ),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: HeadingLevel.none,
          child: Text(
            'Body (Regular)',
            style: TextStyle(
              color: controller.isDarkMode ? Colors.white : Colors.black87,
            ),
          ),
        ),
        PopupMenuItem(
          value: HeadingLevel.h1,
          child: Text(
            'H1 - Heading 1',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
              color: controller.isDarkMode ? Colors.white : Colors.black87,
            ),
          ),
        ),
        PopupMenuItem(
          value: HeadingLevel.h2,
          child: Text(
            'H2 - Heading 2',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: controller.isDarkMode ? Colors.white : Colors.black87,
            ),
          ),
        ),
        PopupMenuItem(
          value: HeadingLevel.h3,
          child: Text(
            'H3 - Heading 3',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
              color: controller.isDarkMode ? Colors.white : Colors.black87,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFontSizeControls(BuildContext context) {
    final currentSize = controller.activeTextFontSize;
    final currentHeading = controller.activeTextHeading;
    final defaultForHeading =
        controller.defaultFontSizeForHeading(currentHeading);
    final isDark = controller.isDarkMode;

    void stepDown() {
      final smaller =
          _standardFontSizes.where((s) => s < currentSize - 0.5).toList();
      final newSize = smaller.isNotEmpty
          ? smaller.last
          : (currentSize - 2).clamp(8.0, 96.0);
      controller.setFontSize(newSize);
    }

    void stepUp() {
      final larger =
          _standardFontSizes.where((s) => s > currentSize + 0.5).toList();
      final newSize = larger.isNotEmpty
          ? larger.first
          : (currentSize + 2).clamp(8.0, 96.0);
      controller.setFontSize(newSize);
    }

    return Container(
      height: 30,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2C2C36) : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isDark ? const Color(0xFF444455) : Colors.grey.shade300,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Decrease font size button
          Tooltip(
            message: 'Decrease font size',
            child: InkWell(
              key: const Key('decrease_font_size_button'),
              borderRadius:
                  const BorderRadius.horizontal(left: Radius.circular(5)),
              onTap: stepDown,
              child: Container(
                width: 22,
                height: 28,
                alignment: Alignment.center,
                child: Icon(
                  Icons.remove_rounded,
                  size: 14,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
            ),
          ),

          // Dropdown for selecting font size
          PopupMenuButton<double>(
            key: const Key('font_size_dropdown'),
            tooltip: 'Font size',
            initialValue: currentSize,
            onSelected: (size) {
              if (size > 0) {
                controller.setFontSize(size);
              }
            },
            color: isDark ? const Color(0xFF2C2C36) : Colors.white,
            padding: EdgeInsets.zero,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              height: 28,
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${currentSize.round()}pt',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 16,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ],
              ),
            ),
            itemBuilder: (context) => [
              // Option to set current font size as default for this heading type
              PopupMenuItem<double>(
                value: -1,
                onTap: () {
                  controller.setPreferredFontSizeForHeading(
                    currentHeading,
                    currentSize,
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Default font size set to ${currentSize.round()}pt for ${currentHeading.label}',
                      ),
                      duration: const Duration(seconds: 2),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                child: Row(
                  children: [
                    Icon(
                      (currentSize - defaultForHeading).abs() < 0.5
                          ? Icons.check_circle_rounded
                          : Icons.bookmark_add_outlined,
                      size: 16,
                      color: (currentSize - defaultForHeading).abs() < 0.5
                          ? const Color(0xFF4CAF50)
                          : (isDark
                              ? const Color(0xFF64B5F6)
                              : const Color(0xFF007AFF)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        (currentSize - defaultForHeading).abs() < 0.5
                            ? '${currentSize.round()}pt is default for ${currentHeading.label}'
                            : 'Set ${currentSize.round()}pt as default for ${currentHeading.label}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              ..._standardFontSizes.map((size) {
                final isCurrent = (currentSize - size).abs() < 0.5;
                final isDefault = (defaultForHeading - size).abs() < 0.5;
                return PopupMenuItem<double>(
                  value: size,
                  child: Row(
                    children: [
                      if (isCurrent)
                        Icon(
                          Icons.check,
                          size: 15,
                          color: isDark
                              ? const Color(0xFF64B5F6)
                              : const Color(0xFF007AFF),
                        )
                      else
                        const SizedBox(width: 15),
                      const SizedBox(width: 8),
                      Text(
                        '${size.toInt()} pt',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              isCurrent ? FontWeight.bold : FontWeight.normal,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      if (isDefault) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF1E2838)
                                : Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: isDark
                                  ? const Color(0xFF2E4568)
                                  : Colors.blue.shade200,
                            ),
                          ),
                          child: Text(
                            'Default',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: isDark
                                  ? const Color(0xFF90CAF9)
                                  : Colors.blue.shade700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }),
            ],
          ),

          // Increase font size button
          Tooltip(
            message: 'Increase font size',
            child: InkWell(
              key: const Key('increase_font_size_button'),
              borderRadius:
                  const BorderRadius.horizontal(right: Radius.circular(5)),
              onTap: stepUp,
              child: Container(
                width: 22,
                height: 28,
                alignment: Alignment.center,
                child: Icon(
                  Icons.add_rounded,
                  size: 14,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormatToggleBtn({
    required String label,
    required bool isActive,
    required VoidCallback onTap,
    required String tooltip,
    bool isBold = false,
    bool isItalic = false,
    bool isUnderline = false,
    bool isStrikethrough = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isActive
                ? (controller.isDarkMode
                    ? const Color(0xFF007AFF).withValues(alpha: 0.35)
                    : const Color(0xFF007AFF).withValues(alpha: 0.15))
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isActive
                  ? const Color(0xFF007AFF)
                  : (controller.isDarkMode
                      ? const Color(0xFF444455)
                      : Colors.grey.shade300),
              width: 1,
            ),
          ),
          child: Builder(builder: (context) {
            final textColor = isActive
                ? (controller.isDarkMode
                    ? const Color(0xFF64B5F6)
                    : const Color(0xFF007AFF))
                : (controller.isDarkMode
                    ? Colors.white70
                    : Colors.black87);
            return Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
                fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
                decoration: TextDecoration.combine([
                  if (isUnderline) TextDecoration.underline,
                  if (isStrikethrough) TextDecoration.lineThrough,
                ]),
                decorationColor: textColor,
                color: textColor,
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildTextColorMenu(BuildContext context) {
    const colors = [
      Colors.black,
      Color(0xFFD32F2F), // Red
      Color(0xFF1976D2), // Blue
      Color(0xFF388E3C), // Green
      Color(0xFF7B1FA2), // Purple
      Color(0xFFF57C00), // Orange
    ];

    return PopupMenuButton<Color>(
      tooltip: 'Font Color',
      onSelected: controller.setTextColor,
      color: controller.isDarkMode ? const Color(0xFF2C2C36) : Colors.white,
      padding: EdgeInsets.zero,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: controller.isDarkMode
              ? const Color(0xFF2C2C36)
              : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: controller.isDarkMode
                ? const Color(0xFF444455)
                : Colors.grey.shade300,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.format_color_text_rounded,
              size: 16,
              color: controller.isDarkMode ? Colors.white70 : Colors.black87,
            ),
            const SizedBox(width: 4),
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: controller.activeTextColor ??
                    (controller.isDarkMode ? Colors.white : Colors.black87),
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
      ),
      itemBuilder: (context) => colors.map((c) {
        return PopupMenuItem<Color>(
          value: c,
          child: Row(
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                c == Colors.black
                    ? 'Black'
                    : '#${c.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
                style: TextStyle(
                  fontSize: 13,
                  color: controller.isDarkMode ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildTextHighlightMenu(BuildContext context) {
    final highlights = [
      null,
      AppColors.highlighterPalette[0], // Yellow
      AppColors.highlighterPalette[1], // Green
      AppColors.highlighterPalette[2], // Cyan
      AppColors.highlighterPalette[3], // Pink
      AppColors.highlighterPalette[4], // Orange
    ];

    return PopupMenuButton<Color?>(
      tooltip: 'Highlight Background',
      onSelected: controller.setTextHighlight,
      color: controller.isDarkMode ? const Color(0xFF2C2C36) : Colors.white,
      padding: EdgeInsets.zero,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: controller.isDarkMode
              ? const Color(0xFF2C2C36)
              : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: controller.isDarkMode
                ? const Color(0xFF444455)
                : Colors.grey.shade300,
          ),
        ),
        child: Icon(
          Icons.border_color_rounded,
          size: 16,
          color: controller.isDarkMode ? Colors.white70 : Colors.black87,
        ),
      ),
      itemBuilder: (context) => highlights.map((c) {
        return PopupMenuItem<Color?>(
          value: c,
          child: Row(
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: c ?? Colors.white,
                  border: Border.all(
                    color: controller.isDarkMode
                        ? Colors.grey.shade600
                        : Colors.grey.shade400,
                  ),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                c == null ? 'None (Clear)' : 'Highlight',
                style: TextStyle(
                  fontSize: 13,
                  color: controller.isDarkMode ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildImageMenuButton(BuildContext context) {
    return PopupMenuButton<String>(
      key: const Key('insert_image_button'),
      tooltip: 'Insert or Paste Image',
      offset: const Offset(0, 36),
      color: controller.isDarkMode ? const Color(0xFF2C2C36) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: controller.isDarkMode
              ? const Color(0xFF2C2C36)
              : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: controller.isDarkMode
                ? const Color(0xFF444455)
                : Colors.grey.shade300,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.add_photo_alternate_outlined,
              size: 16,
              color: controller.isDarkMode
                  ? const Color(0xFF64B5F6)
                  : const Color(0xFF007AFF),
            ),
            const SizedBox(width: 4),
            Text(
              'Image',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: controller.isDarkMode
                    ? const Color(0xFF64B5F6)
                    : const Color(0xFF007AFF),
              ),
            ),
            Icon(
              Icons.arrow_drop_down,
              size: 16,
              color: controller.isDarkMode ? Colors.white70 : Colors.grey,
            ),
          ],
        ),
      ),
      onSelected: (choice) async {
        if (choice == 'clipboard') {
          final success = await controller.pasteImageFromClipboard();
          if (!success && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'No image found on clipboard to paste. Copy an image first!',
                ),
                duration: Duration(seconds: 2),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        } else if (choice == 'device') {
          await controller.pickAndInsertImage();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'clipboard',
          child: Row(
            children: [
              Icon(
                Icons.content_paste_rounded,
                size: 18,
                color: controller.isDarkMode
                    ? const Color(0xFF64B5F6)
                    : const Color(0xFF007AFF),
              ),
              const SizedBox(width: 8),
              Text(
                'Paste from Clipboard (Ctrl+V)',
                style: TextStyle(
                  color: controller.isDarkMode ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'device',
          child: Row(
            children: [
              Icon(
                Icons.upload_file_rounded,
                size: 18,
                color: controller.isDarkMode ? Colors.white70 : Colors.black87,
              ),
              const SizedBox(width: 8),
              Text(
                'Upload Image File...',
                style: TextStyle(
                  color: controller.isDarkMode ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
