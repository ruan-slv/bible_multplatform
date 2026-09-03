// Tests for the Bible app: JSON decoding (unit) + widget flow (mobile/desktop).
//
// The widget tests inject a pre-loaded dataset via [bibleLoader] (loaded once
// with dart:io in setUpAll) so they are deterministic and fast — no real asset
// I/O, no runAsync polling, no flakiness from the cold first decode.

import 'dart:io' as io;

import 'package:bible_lite/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads the real 4 MB asset ONCE per test run (outside the fake-async zone)
/// and points the app's injectable loader at it.
Future<void> _useRealAsset() async {
  final raw = io.File('assets/json/nvi.json').readAsStringSync();
  final books = BibleBook.decodeAll(raw);
  bibleLoader = () async => books;
}

void main() {
  setUpAll(_useRealAsset);

  group('BibleBook.decodeAll', () {
    test('parses a valid payload (BOM + array of books)', () {
      // Leading \uFEFF mimics the real file's UTF-8 BOM.
      final raw = '''
\uFEFF[
  {"abbrev":"gn","name":"Gênesis","chapters":[
     ["No princípio Deus criou os céus e a terra.","E era a terra sem forma."],
     ["Capítulo dois."]
  ]},
  {"abbrev":"ex","name":"Êxodo","chapters":[["Único."]]}
]''';

      final books = BibleBook.decodeAll(raw);

      expect(books, hasLength(2));
      expect(books[0].name, 'Gênesis');
      expect(books[0].abbrev, 'gn');
      expect(books[0].chapters, hasLength(2));
      expect(books[0].chapters[0], hasLength(2));
      expect(books[0].chapters[0][0],
          'No princípio Deus criou os céus e a terra.');
      expect(books[1].chapters[0][0], 'Único.');
    });

    test('throws on a non-array payload', () {
      expect(
        () => BibleBook.decodeAll('{"abbrev":"gn"}'),
        throwsFormatException,
      );
    });

    test('throws on garbage text', () {
      expect(
        () => BibleBook.decodeAll('isso não é json'),
        throwsFormatException,
      );
    });
  });

  /// Pumps the app at [size] and waits (fake-async) until the books are in.
  /// The injected loader is an async closure that resolves on a microtask, so
  /// a few pumps are enough — no real I/O, no runAsync.
  Future<void> loadApp(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const BibleApp());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(CircularProgressIndicator), findsNothing);
  }

  group('BibleApp mobile layout (800x600 < 900 breakpoint)', () {
    testWidgets('loads, opens the drawer, jumps to João 3:16',
        (WidgetTester tester) async {
      await loadApp(tester, const Size(800, 600));

      // Compact layout: books live in the drawer (not built until opened),
      // the header shows the book name in caps and chapter 1 of Gênesis.
      expect(find.text('GÊNESIS'), findsOneWidget);
      expect(find.text('Capítulo 1'), findsOneWidget);
      expect(
        find.text('No princípio Deus criou os céus e a terra.'),
        findsOneWidget,
      );

      // Open the drawer and select João (index 42 in the 66-book list).
      await tester.tap(find.byKey(const ValueKey('menuButton')));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('book-42')),
        find.byKey(const ValueKey('bookList')),
        const Offset(0, -150),
      );
      await tester.tap(find.byKey(const ValueKey('book-42')));
      await tester.pumpAndSettle();
      expect(find.text('JOÃO'), findsOneWidget);
      expect(
        find.text('No princípio era aquele que é a Palavra. Ele estava com '
            'Deus, e era Deus.'),
        findsOneWidget,
      );

      // Select chapter 3 via the horizontal chip strip.
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('chapter-2')),
        find.byKey(const ValueKey('chapterList')),
        const Offset(0, -150),
      );
      await tester.tap(find.byKey(const ValueKey('chapter-2')));
      await tester.pump();
      expect(find.text('Capítulo 3'), findsOneWidget);

      // Verse 16 is below the fold in the 600px viewport: drag the lazy
      // verse list until it is built (ensureVisible can't reach unbuilt items).
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('verse-15')),
        find.byKey(const ValueKey('verseList')),
        const Offset(0, -150),
      );
      // NVI 3:16 starts with a literal opening quote in the source data.
      expect(
        find.text('"Porque Deus tanto amou o mundo que deu o seu '
            'Filho Unigênito, para que todo o que nele crer não pereça, '
            'mas tenha a vida eterna.'),
        findsOneWidget,
      );
    });
  });

  group('BibleApp desktop layout (1280x800 >= 900 breakpoint)', () {
    testWidgets('shows the three panes and switches books',
        (WidgetTester tester) async {
      // Force a wide viewport so the desktop layout is used.
      await loadApp(tester, const Size(1280, 800));

      // Book rail (not in a drawer): "Gênesis" in original case, plus the
      // header "GÊNESIS" / "Capítulo 1".
      expect(find.text('Gênesis'), findsOneWidget);
      expect(find.text('GÊNESIS'), findsOneWidget);
      expect(find.text('Capítulo 1'), findsOneWidget);
      expect(
        find.text('No princípio Deus criou os céus e a terra.'),
        findsOneWidget,
      );

      // Chapter rail: chapter 2 is a visible chip next to the selected 1.
      expect(find.byKey(const ValueKey('chapter-1')), findsOneWidget);

      // Switch to Êxodo (index 1) via the book rail.
      await tester.tap(find.byKey(const ValueKey('book-1')));
      await tester.pump();
      expect(find.text('ÊXODO'), findsOneWidget);
      expect(
        find.text('São estes, pois, os nomes dos filhos de Israel que '
            'entraram com Jacó no Egito, cada um com a sua respectiva '
            'família:'),
        findsOneWidget,
      );
    });
  });
}
