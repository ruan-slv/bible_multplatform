import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const BibleApp());

/// Injectable book loader. Defaults to the bundled-asset loader; widget tests
/// swap it for a pre-loaded dataset so they are deterministic and fast (no real
/// I/O, no `runAsync` polling).
Future<List<BibleBook>> Function() bibleLoader = BibleBook.load;

// ---------------------------------------------------------------------------
// Palette & typography — a warm "old book" look: deep brown, gold, paper.
// ---------------------------------------------------------------------------

const Color _brown = Color(0xFF5D4037);
const Color _brownDark = Color(0xFF3B2A22);
const Color _gold = Color(0xFFC68B3E);
const Color _paper = Color(0xFFF7F3EC);
const Color _card = Color(0xFFFFFCF7);
const Color _ink = Color(0xFF2B2622);
const Color _muted = Color(0xFF7A6E63);
const Color _line = Color(0xFFE3D9CC);
const Color _tint = Color(0xFFEAD9C4);

/// Serif stack for verse text: Georgia (desktop) → Noto Serif (Android) → serif.
const String _serif = 'Georgia, "Times New Roman", "Noto Serif", serif';

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// One book of the Bible (NVI).
///
/// JSON shape: `[{"abbrev": "gn", "name": "Gênesis", "chapters": [[...], ...]}]`
/// `chapters` is a list of chapters; each chapter is a list of verse strings.
class BibleBook {
  final String name;
  final String abbrev;
  final List<List<String>> chapters;

  const BibleBook({
    required this.name,
    required this.abbrev,
    required this.chapters,
  });

  /// Parses a single JSON object into a [BibleBook].
  factory BibleBook.fromJson(Map<String, dynamic> json) {
    final rawChapters = json['chapters'] as List;
    return BibleBook(
      name: json['name'] as String? ?? json['abbrev'] as String,
      abbrev: json['abbrev'] as String,
      chapters: rawChapters
          .map((c) => (c as List).map((v) => v as String).toList())
          .toList(),
    );
  }

  /// Decodes the raw asset text into the list of all books.
  ///
  /// The real file starts with a UTF-8 BOM (`\uFEFF`), which `jsonDecode`
  /// rejects ("Unexpected character at 1"), so it is stripped first — an
  /// O(1) prefix check plus one O(n) `substring`, no full scan.
  static List<BibleBook> decodeAll(String raw) {
    final text = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
    final dynamic decoded = jsonDecode(text);
    if (decoded is! List) {
      throw const FormatException('nvi.json: expected a JSON array of books');
    }
    return decoded
        .map((b) => BibleBook.fromJson(b as Map<String, dynamic>))
        .toList();
  }

  /// Loads the bundled `assets/json/nvi.json` and decodes it.
  ///
  /// O(n) in file size; the 4 MB payload is decoded once at startup and kept
  /// in memory — no repeated IO, no extra packages.
  static Future<List<BibleBook>> load() async {
    final raw = await rootBundle.loadString('assets/json/nvi.json');
    return decodeAll(raw);
  }
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

/// Root widget: a [StatefulWidget] whose [State] owns ALL mutable state and
/// rebuilds the UI exclusively through `setState` (no providers, no blocs).
///
/// Responsive strategy:
///  * width < 900 (phones / portrait tablets) → single reading pane, books in
///    a drawer, chapters as a horizontal chip strip;
///  * width >= 900 (desktops / landscape tablets) → three panes: book list,
///    chapter rail, centered reading column (max 780 px for readability).
class BibleApp extends StatefulWidget {
  const BibleApp({super.key});

  @override
  State<BibleApp> createState() => _BibleAppState();
}

class _BibleAppState extends State<BibleApp> {
  // --- state ---------------------------------------------------------------
  /// `null` while the asset is still being read.
  List<BibleBook>? _books;
  Object? _error;

  int _bookIndex = 0;
  int _chapterIndex = 0;
  bool _showJumpDialog = false;

  /// Text in the book search field (shared by the drawer and the desktop panel).
  String _bookFilter = '';

  final _bookSearchCtrl = TextEditingController();
  final _chapterScrollCtrl = ScrollController();

  /// Below this logical width the compact (mobile) layout is used.
  static const double _compactBreakpoint = 900;

  static final ThemeData _theme = ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: _paper,
    colorScheme: ColorScheme(
      brightness: Brightness.light,
      primary: _brown,
      onPrimary: Colors.white,
      primaryContainer: _tint,
      onPrimaryContainer: _brownDark,
      secondary: _gold,
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFF3E5C8),
      onSecondaryContainer: const Color(0xFF5A3E1B),
      surface: _card,
      onSurface: _ink,
      surfaceContainerHighest: const Color(0xFFEFE7DB),
      onSurfaceVariant: _muted,
      outline: _line,
      error: const Color(0xFFB3261E),
      onError: Colors.white,
    ),
  );

  @override
  void initState() {
    super.initState();
    // Load the books once via the injectable loader; the UI shows a spinner
    // until it resolves.
    bibleLoader().then((books) {
      if (!mounted) return;
      setState(() {
        _books = books;
        _error = null;
      });
    }).catchError((Object e) {
      if (!mounted) return;
      setState(() => _error = e);
    });
  }

  @override
  void dispose() {
    _bookSearchCtrl.dispose();
    _chapterScrollCtrl.dispose();
    super.dispose();
  }

  // --- navigation helpers (each mutates state and triggers a rebuild) ------

  void _selectBook(int index) {
    setState(() {
      _bookIndex = index;
      _chapterIndex = 0; // always open the first chapter of a new book
    });
    _scrollChapterTo(0);
  }

  void _selectChapter(int index) {
    setState(() => _chapterIndex = index);
    _scrollChapterTo(index);
  }

  /// Keeps the selected chapter chip visible in the mobile strip (no-op on
  /// desktop, where the rail has no controller attached).
  void _scrollChapterTo(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_chapterScrollCtrl.hasClients) return;
      final max = _chapterScrollCtrl.position.maxScrollExtent;
      // One chip slot ≈ 56 px (48 chip + 8 margin); keep ~2 chips of margin.
      _chapterScrollCtrl.jumpTo((index * 56.0 - 140.0).clamp(0.0, max).toDouble());
    });
  }

  /// Opens the "jump to book:chapter" dialog, pre-filled with the current ref.
  void _openJumpDialog() {
    setState(() => _showJumpDialog = true);
  }

  /// Confirms the jump dialog. Returns true when a valid reference was entered.
  bool _onJumpSubmitted(String bookQuery, String chapterQuery) {
    final books = _books!;
    if (bookQuery.trim().isEmpty && chapterQuery.trim().isEmpty) {
      return false; // nothing typed: keep current selection
    }

    final int targetBook;
    if (bookQuery.trim().isNotEmpty) {
      final q = bookQuery.trim().toLowerCase();
      final found = books.indexWhere(
        (b) => b.name.toLowerCase().startsWith(q) ||
            b.abbrev.toLowerCase() == q,
      );
      if (found == -1) return false; // book not found
      targetBook = found;
    } else {
      targetBook = _bookIndex;
    }

    final book = books[targetBook];
    int targetChapter = _chapterIndex;
    if (chapterQuery.trim().isNotEmpty) {
      final c = int.tryParse(chapterQuery.trim()) ?? 0;
      targetChapter = c.clamp(1, book.chapters.length) - 1;
    }

    setState(() {
      _bookIndex = targetBook;
      _chapterIndex = targetChapter;
      _showJumpDialog = false;
    });
    return true;
  }

  // --- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bíblia NVI',
      debugShowCheckedModeBanner: false,
      theme: _theme,
      home: Builder(builder: (context) {
        // MediaQuery is only available below MaterialApp, hence the Builder.
        final compact =
            MediaQuery.sizeOf(context).width < _compactBreakpoint;
        return Scaffold(
          appBar: _appBar(context, compact),
          drawer: compact ? _drawer : null,
          body: _showJumpDialog ? _wrapJumpDialog(_body(context, compact))
              : _body(context, compact),
        );
      }),
    );
  }

  AppBar _appBar(BuildContext context, bool compact) {
    return AppBar(
      backgroundColor: _brownDark,
      foregroundColor: Colors.white,
      elevation: 0,
      // Thin gold rule under the bar — a subtle "gilt edge" accent.
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(2),
        child: Container(color: _gold),
      ),
      // A nested Builder is required: the `context` passed to _appBar is the
      // one that BUILDS the Scaffold, so Scaffold.of(context) from there finds
      // no ancestor Scaffold.
      leading: compact
          ? Builder(
              builder: (c) => IconButton(
                key: const ValueKey('menuButton'),
                icon: const Icon(Icons.menu),
                tooltip: 'Livros',
                onPressed: () => Scaffold.of(c).openDrawer(),
              ),
            )
          : null,
      title: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.menu_book, color: _gold, size: 22),
          SizedBox(width: 10),
          Text(
            'Bíblia NVI',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'Ir para…',
          onPressed:
              _books != null && !_showJumpDialog ? _openJumpDialog : null,
        ),
      ],
    );
  }

  /// Mobile book browser: search + full list, in a 300 px drawer.
  Widget get _drawer => Drawer(
        width: 300,
        child: _books == null
            ? const SizedBox.shrink()
            : Builder(builder: (c) => _bookPanel(c, inDrawer: true)),
      );

  Widget _body(BuildContext context, bool compact) {
    if (_error != null) return _errorScreen;

    final books = _books;
    if (books == null) return _loadingScreen;

    final book = books[_bookIndex];
    final verses = book.chapters[_chapterIndex];

    if (compact) {
      return Column(
        children: [
          _chapterStrip(book),
          const Divider(height: 1, color: _line),
          Expanded(child: _readingPane(context, book, verses)),
        ],
      );
    }

    return Row(
      children: [
        // Left rail: book list with search.
        SizedBox(width: 280, child: _bookPanel(context, inDrawer: false)),
        const VerticalDivider(width: 1, color: _line),
        // Middle rail: chapter numbers of the selected book.
        SizedBox(width: 132, child: _chapterRail(book)),
        const VerticalDivider(width: 1, color: _line),
        // Main pane: verses of the selected chapter.
        Expanded(child: _readingPane(context, book, verses)),
      ],
    );
  }

  // --- shared screens ------------------------------------------------------

  Widget get _loadingScreen => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu_book, size: 64, color: _gold),
            const SizedBox(height: 28),
            const CircularProgressIndicator(color: _brown),
            const SizedBox(height: 24),
            const Text(
              'Carregando a Bíblia…',
              style: TextStyle(color: _muted, fontSize: 14, letterSpacing: 0.5),
            ),
          ],
        ),
      );

  Widget get _errorScreen => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 56, color: Color(0xFFB3261E)),
              const SizedBox(height: 16),
              Text(
                'Falha ao carregar a Bíblia:\n$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: _ink, fontSize: 14, height: 1.5),
              ),
            ],
          ),
        ),
      );

  // --- book panel (drawer on mobile, left rail on desktop) ------------------

  /// Books matching the current search, paired with their index in the FULL
  /// list so widget keys stay stable while filtering.
  List<(BibleBook, int)> _filteredBooks() {
    final books = _books!;
    final q = _bookFilter.trim().toLowerCase();
    return [
      for (var i = 0; i < books.length; i++)
        if (q.isEmpty ||
            books[i].name.toLowerCase().contains(q) ||
            books[i].abbrev.toLowerCase() == q)
          (books[i], i),
    ];
  }

  Widget _bookPanel(BuildContext context, {required bool inDrawer}) {
    final filtered = _filteredBooks();
    return Container(
      color: _card,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'LIVROS',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.5,
                    color: _gold,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _bookSearchCtrl,
                  onChanged: (v) => setState(() => _bookFilter = v),
                  style: const TextStyle(fontSize: 14, color: _ink),
                  decoration: InputDecoration(
                    hintText: 'Buscar livro…',
                    hintStyle: const TextStyle(color: _muted, fontSize: 13),
                    prefixIcon: const Icon(Icons.search, size: 20, color: _muted),
                    suffixIcon: _bookFilter.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear,
                                size: 18, color: _muted),
                            onPressed: () {
                              _bookSearchCtrl.clear();
                              setState(() => _bookFilter = '');
                            },
                          ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _line),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _gold, width: 1.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _line),
          Expanded(
            child: ListView.separated(
              key: const ValueKey('bookList'),
              padding: const EdgeInsets.all(8),
              itemCount: filtered.length,
              separatorBuilder: (_, _) => const SizedBox(height: 2),
              itemBuilder: (context, i) {
                final (book, idx) = filtered[i];
                final selected = idx == _bookIndex;
                return InkWell(
                  key: ValueKey('book-$idx'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    _selectBook(idx);
                    if (inDrawer) Navigator.of(context).pop();
                  },
                  child: Ink(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 9),
                    decoration: selected
                        ? BoxDecoration(
                            color: _tint,
                            borderRadius: BorderRadius.circular(12),
                          )
                        : null,
                    child: Row(
                      children: [
                        if (selected)
                          const Padding(
                            padding: EdgeInsets.only(right: 10),
                            child: Icon(Icons.bookmark,
                                size: 16, color: _brown),
                          ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                book.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: selected ? _brownDark : _ink,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                '${book.chapters.length} capítulos',
                                style:
                                    const TextStyle(fontSize: 11, color: _muted),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // --- chapters -------------------------------------------------------------

  /// Mobile: horizontal chip strip pinned above the reading pane.
  ///
  /// A horizontal [ListView] inside a [Column] would otherwise receive an
  /// unbounded height (its cross axis) and fail to lay out, so the strip is
  /// given an explicit height matching the chip size.
  Widget _chapterStrip(BibleBook book) {
    return Container(
      color: _card,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: SizedBox(
        height: 36,
        child: ListView(
          key: const ValueKey('chapterList'),
          controller: _chapterScrollCtrl,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.zero,
          children: [
            for (var i = 0; i < book.chapters.length; i++)
              Padding(
                key: ValueKey('chapter-$i'),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: _chapterChip(i),
              ),
          ],
        ),
      ),
    );
  }

  /// Desktop: vertical rail of numbered chips.
  Widget _chapterRail(BibleBook book) {
    return ListView.builder(
      key: const ValueKey('chapterList'),
      padding: const EdgeInsets.all(12),
      itemCount: book.chapters.length,
      itemBuilder: (context, i) {
        final selected = i == _chapterIndex;
        return Padding(
          key: ValueKey('chapter-$i'),
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _selectChapter(i),
            child: Ink(
              width: 48,
              height: 42,
              decoration: BoxDecoration(
                color: selected ? _brown : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: selected ? null : Border.all(color: _line),
              ),
              child: Center(
                child: Text(
                  '${i + 1}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : _brown,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _chapterChip(int i) {
    final selected = i == _chapterIndex;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _selectChapter(i),
      child: Ink(
        width: 48,
        height: 36,
        decoration: BoxDecoration(
          color: selected ? _brown : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: selected ? null : Border.all(color: _line),
        ),
        child: Center(
          child: Text(
            '${i + 1}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : _brown,
            ),
          ),
        ),
      ),
    );
  }

  // --- reading pane ----------------------------------------------------------

  Widget _readingPane(BuildContext context, BibleBook book,
      List<String> verses) {
    final total = book.chapters.length;
    return Column(
      children: [
        // Header: chapter navigation + book name + chapter number.
        // Constrained to 780 px (same as the verse column) and centered, so
        // on very narrow windows the buttons never overflow the Row.
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: Row(
                children: [
                  _navButton(
                    enabled: _chapterIndex > 0,
                    onTap: () => _selectChapter(_chapterIndex - 1),
                    icon: Icons.chevron_left,
                    tooltip: 'Capítulo anterior',
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          book.name.toUpperCase(),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2.5,
                            color: _gold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Capítulo ${_chapterIndex + 1}',
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: _serif,
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            color: _ink,
                          ),
                        ),
                        Text(
                          'de $total capítulos',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 11, color: _muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _navButton(
                    enabled: _chapterIndex < total - 1,
                    onTap: () => _selectChapter(_chapterIndex + 1),
                    icon: Icons.chevron_right,
                    tooltip: 'Próximo capítulo',
                  ),
                ],
              ),
            ),
          ),
        ),
        const Divider(height: 1, color: _line),
        // Verses, centered in a comfortable 780 px column on wide screens.
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: ListView.builder(
                key: const ValueKey('verseList'),
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 28),
                itemCount: verses.length,
                itemBuilder: (context, i) => _verse(i, verses[i]),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _verse(int i, String text) {
    return Padding(
      key: ValueKey('verse-$i'),
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 26),
            child: Text(
              '${i + 1}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontFamily: _serif,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _gold,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: _serif,
                fontSize: 17,
                height: 1.65,
                color: _ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _navButton(
      {required bool enabled,
      required VoidCallback? onTap,
      required IconData icon,
      required String tooltip}) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: enabled ? onTap : null,
        icon: Icon(icon, size: 22),
        style: IconButton.styleFrom(
          backgroundColor: enabled ? _tint : Colors.transparent,
          foregroundColor: _brown,
          disabledForegroundColor: _line,
          minimumSize: const Size(44, 44),
        ),
      ),
    );
  }

  Widget _wrapJumpDialog(Widget child) {
    return Stack(
      children: [
        child,
        const ModalBarrier(color: Colors.black54),
        Center(
          child: _JumpDialog(
            books: _books!,
            currentBookIndex: _bookIndex,
            currentChapterIndex: _chapterIndex,
            onSubmitted: _onJumpSubmitted,
            onDismissed: () => setState(() => _showJumpDialog = false),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Jump dialog
// ---------------------------------------------------------------------------

/// Small stateful dialog: keeps its own text controllers and a local feedback
/// message. Navigation state itself still lives in [_BibleAppState]; the
/// callbacks here just report back to it.
class _JumpDialog extends StatefulWidget {
  final List<BibleBook> books;
  final int currentBookIndex;
  final int currentChapterIndex;
  final bool Function(String book, String chapter) onSubmitted;
  final VoidCallback onDismissed;

  const _JumpDialog({
    required this.books,
    required this.currentBookIndex,
    required this.currentChapterIndex,
    required this.onSubmitted,
    required this.onDismissed,
  });

  @override
  State<_JumpDialog> createState() => _JumpDialogState();
}

class _JumpDialogState extends State<_JumpDialog> {
  late final TextEditingController _bookCtrl = TextEditingController(
    text: widget.books[widget.currentBookIndex].name,
  );
  late final TextEditingController _chapterCtrl = TextEditingController(
    text: '${widget.currentChapterIndex + 1}',
  );
  final _formKey = GlobalKey<FormState>();
  String? _feedback;

  @override
  void dispose() {
    _bookCtrl.dispose();
    _chapterCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!widget.onSubmitted(_bookCtrl.text, _chapterCtrl.text)) {
      setState(() => _feedback = 'Livro não encontrado.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 10,
      color: _card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: _line),
      ),
      margin: const EdgeInsets.all(24),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Row(
                children: [
                  Icon(Icons.explore, color: _gold, size: 22),
                  SizedBox(width: 10),
                  Text(
                    'Ir para…',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: _ink,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Form(
                key: _formKey,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _bookCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Livro (nome ou sigla)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _chapterCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Capítulo',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      validator: (v) {
                        final t = v?.trim() ?? '';
                        if (t.isEmpty) return null;
                        final c = int.tryParse(t);
                        return (c == null || c < 1) ? 'Capítulo inválido' : null;
                      },
                    ),
                  ],
                ),
              ),
              if (_feedback != null) ...[
                const SizedBox(height: 12),
                Text(
                  _feedback!,
                  style: const TextStyle(color: Color(0xFFB3261E), fontSize: 13),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: widget.onDismissed,
                    child: const Text('Cancelar'),
                  ),
                  FilledButton(onPressed: _submit, child: const Text('Ir')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
