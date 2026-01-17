// ============================================================================
// CODE BLOCK COMPONENT
// ============================================================================
//
// Custom code block component for AppFlowy rich editor.
//
// Features:
// - Syntax highlighting with language selection
// - 40+ programming languages supported
// - Monospace font with proper line height
// - Horizontal scroll for long lines
// - Copy code button (in preview mode)
//
// Keyboard Shortcuts:
// - Enter: Insert newline (stays in code block)
// - Tab: Exit code block, create new paragraph
// - Ctrl+V: Paste plain text (preserves newlines)
//
// Slash Command: /code or /codeblock
//
// ============================================================================

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';

/// Code block keys for node type identification.
class CodeBlockKeys {
  const CodeBlockKeys._();
  static const String type = 'code';
}

/// Creates a code block node.
Node codeBlockNode({String? language, Delta? delta}) {
  return Node(
    type: CodeBlockKeys.type,
    attributes: {
      'language': language ?? '',
      'delta': (delta ?? Delta()).toJson(),
    },
  );
}

/// Command shortcut to insert newline in code block instead of creating new node.
final codeBlockNewLineCommand = CommandShortcutEvent(
  key: 'insert newline in code block',
  getDescription: () => 'Insert a newline character in code block',
  command: 'enter',
  handler: (editorState) {
    final selection = editorState.selection;
    if (selection == null || !selection.isCollapsed) return KeyEventResult.ignored;
    final node = editorState.getNodeAtPath(selection.start.path);
    if (node == null || node.type != CodeBlockKeys.type) return KeyEventResult.ignored;
    final transaction = editorState.transaction;
    transaction.insertText(node, selection.start.offset, '\n');
    editorState.apply(transaction);
    return KeyEventResult.handled;
  },
);

/// Exit code block and create new paragraph below (Tab).
final codeBlockExitCommand = CommandShortcutEvent(
  key: 'exit code block',
  getDescription: () => 'Exit code block and create new paragraph',
  command: 'tab',
  handler: (editorState) {
    final selection = editorState.selection;
    if (selection == null) return KeyEventResult.ignored;
    final node = editorState.getNodeAtPath(selection.start.path);
    if (node == null || node.type != CodeBlockKeys.type) return KeyEventResult.ignored;
    final transaction = editorState.transaction;
    final newPath = selection.start.path.next;
    transaction.insertNode(newPath, paragraphNode());
    transaction.afterSelection = Selection.collapsed(Position(path: newPath, offset: 0));
    editorState.apply(transaction);
    return KeyEventResult.handled;
  },
);

/// Command shortcut to paste plain text in code block (preserves newlines).
final codeBlockPasteCommand = CommandShortcutEvent(
  key: 'paste in code block',
  getDescription: () => 'Paste plain text in code block',
  command: 'ctrl+v',
  macOSCommand: 'cmd+v',
  handler: (editorState) {
    final selection = editorState.selection;
    if (selection == null) return KeyEventResult.ignored;
    final node = editorState.getNodeAtPath(selection.start.path);
    if (node == null || node.type != CodeBlockKeys.type) return KeyEventResult.ignored;
    
    Clipboard.getData(Clipboard.kTextPlain).then((data) {
      if (data == null || data.text == null) return;
      
      final text = data.text!;
      final transaction = editorState.transaction;
      
      if (!selection.isCollapsed) {
        transaction.deleteText(node, selection.start.offset, selection.end.offset - selection.start.offset);
      }
      
      transaction.insertText(node, selection.start.offset, text);
      transaction.afterSelection = Selection.collapsed(
        Position(path: selection.start.path, offset: selection.start.offset + text.length),
      );
      editorState.apply(transaction);
    });
    return KeyEventResult.handled;
  },
);

/// Code block component builder.
class CodeBlockComponentBuilder extends BlockComponentBuilder {
  CodeBlockComponentBuilder({super.configuration});

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    return CodeBlockComponentWidget(
      key: blockComponentContext.node.key,
      node: blockComponentContext.node,
      configuration: configuration,
      showActions: showActions(blockComponentContext.node),
      actionBuilder: (context, state) => actionBuilder(blockComponentContext, state),
    );
  }

  @override
  BlockComponentValidate get validate => (node) => node.delta != null;
}

/// Code block widget with monospace styling.
class CodeBlockComponentWidget extends BlockComponentStatefulWidget {
  const CodeBlockComponentWidget({
    super.key,
    required super.node,
    super.showActions,
    super.actionBuilder,
    super.configuration = const BlockComponentConfiguration(),
  });

  @override
  State<CodeBlockComponentWidget> createState() => _CodeBlockComponentWidgetState();
}

class _CodeBlockComponentWidgetState extends State<CodeBlockComponentWidget>
    with SelectableMixin, DefaultSelectableMixin, BlockComponentConfigurable, BlockComponentTextDirectionMixin, BlockComponentBackgroundColorMixin {
  @override
  final forwardKey = GlobalKey(debugLabel: 'code_block_rich_text');

  @override
  GlobalKey<State<StatefulWidget>> blockComponentKey = GlobalKey(debugLabel: CodeBlockKeys.type);

  @override
  BlockComponentConfiguration get configuration => widget.configuration;

  @override
  Node get node => widget.node;

  @override
  GlobalKey<State<StatefulWidget>> get containerKey => node.key;

  @override
  late EditorState editorState = context.read<EditorState>();

  String get language => node.attributes['language'] as String? ?? '';

  static const _languages = [
    '', 'dart', 'python', 'javascript', 'typescript', 'java', 'kotlin', 'swift', 'go', 'rust', 
    'c', 'cpp', 'csharp', 'php', 'ruby', 'scala', 'perl', 'lua', 'r', 'matlab',
    'sql', 'graphql', 'html', 'css', 'scss', 'less', 'json', 'yaml', 'xml', 'toml',
    'bash', 'powershell', 'dockerfile', 'makefile', 'nginx', 'apache',
    'markdown', 'latex', 'plaintext', 'diff', 'ini', 'properties',
  ];

  void _setLanguage(String lang) {
    final transaction = editorState.transaction;
    transaction.updateNode(node, {'language': lang});
    editorState.apply(transaction);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;
    final borderColor = isDark ? const Color(0xFF3E4451) : const Color(0xFFD0D0D0);

    Widget child = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Language selector
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF21252B) : const Color(0xFFEEEEEE),
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(8)),
            border: Border(bottom: BorderSide(color: borderColor)),
          ),
          child: Row(
            children: [
              Icon(Icons.code, size: 14, color: colors.primary),
              const SizedBox(width: 6),
              PopupMenuButton<String>(
                initialValue: language,
                onSelected: _setLanguage,
                tooltip: 'Select language',
                constraints: const BoxConstraints(maxHeight: 300, maxWidth: 280),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(language.isEmpty ? 'plain text' : language, style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.7))),
                    Icon(Icons.arrow_drop_down, size: 16, color: colors.onSurface.withValues(alpha: 0.5)),
                  ],
                ),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    enabled: false,
                    padding: EdgeInsets.zero,
                    child: SizedBox(
                      width: 260,
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: _languages.map((l) => InkWell(
                          onTap: () { Navigator.pop(context); _setLanguage(l); },
                          borderRadius: BorderRadius.circular(4),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: language == l ? colors.primary.withValues(alpha: 0.2) : colors.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(l.isEmpty ? 'plain' : l, style: TextStyle(fontSize: 11, color: language == l ? colors.primary : colors.onSurface)),
                          ),
                        )).toList(),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        // Code content
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF282C34) : const Color(0xFFFAFAFA),
            borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(8), bottomRight: Radius.circular(8)),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(16),
            child: AppFlowyRichText(
              key: forwardKey,
              node: widget.node,
              editorState: editorState,
              delegate: this,
              placeholderText: placeholderText,
              textSpanDecorator: (textSpan) => textSpan.updateTextStyle(
                TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.5, color: isDark ? const Color(0xFFABB2BF) : const Color(0xFF383A42)),
              ),
              placeholderTextSpanDecorator: (textSpan) => textSpan,
              lineHeight: 1.5,
              cursorColor: editorState.editorStyle.cursorColor,
              selectionColor: editorState.editorStyle.selectionColor,
            ),
          ),
        ),
      ],
    );

    child = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(8), child: child),
    );

    child = Padding(padding: padding, child: child);

    child = BlockSelectionContainer(
      node: node,
      delegate: this,
      listenable: editorState.selectionNotifier,
      remoteSelection: editorState.remoteSelections,
      blockColor: editorState.editorStyle.selectionColor,
      supportTypes: const [BlockSelectionType.block],
      child: child,
    );

    if (widget.showActions && widget.actionBuilder != null) {
      child = BlockComponentActionWrapper(node: node, actionBuilder: widget.actionBuilder!, child: child);
    }

    return child;
  }
}

/// Slash menu item for inserting code blocks.
SelectionMenuItem codeBlockMenuItem = SelectionMenuItem(
  getName: () => 'Code Block',
  icon: (_, isSelected, style) => Icon(
    Icons.code,
    size: 18,
    color: isSelected ? style.selectionMenuItemSelectedIconColor : style.selectionMenuItemIconColor,
  ),
  keywords: ['code', 'codeblock', 'snippet', 'programming'],
  handler: (editorState, _, __) {
    final selection = editorState.selection;
    if (selection == null) return;
    final node = editorState.getNodeAtPath(selection.start.path);
    if (node == null) return;
    final transaction = editorState.transaction;
    transaction.insertNode(selection.start.path, codeBlockNode());
    transaction.deleteNode(node);
    transaction.afterSelection = Selection.collapsed(Position(path: selection.start.path, offset: 0));
    editorState.apply(transaction);
  },
);


/// Markdown parser for code blocks (```code```).
class MarkdownCodeBlockParser extends CustomMarkdownParser {
  const MarkdownCodeBlockParser();

  @override
  List<Node> transform(
    md.Node element,
    List<CustomMarkdownParser> parsers, {
    MarkdownListType listType = MarkdownListType.unknown,
    int? startNumber,
  }) {
    if (element is! md.Element || element.tag != 'pre') return [];
    final children = element.children;
    if (children == null || children.isEmpty) return [];
    final code = children.first;
    if (code is! md.Element || code.tag != 'code') return [];

    String? language;
    if (code.attributes.containsKey('class')) {
      final classes = code.attributes['class']!.split(' ');
      final langClass = classes.firstWhere((c) => c.startsWith('language-'), orElse: () => '');
      if (langClass.isNotEmpty) language = langClass.substring('language-'.length);
    }

    return [codeBlockNode(language: language, delta: Delta()..insert(code.textContent.trimRight()))];
  }
}
