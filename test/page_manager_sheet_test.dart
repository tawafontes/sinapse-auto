import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/widgets/dashboard/page_manager_sheet.dart';

void main() {
  const grid = (columns: 4, rows: 4);
  const anyRect = (x: 0, y: 0, width: 1, height: 1);

  PageManagerEntry entry(SensorType type) => (type: type, rect: anyRect);

  Future<void> pumpSheet(
    WidgetTester tester, {
    required List<List<PageManagerEntry>> pages,
    int currentPage = 0,
    int maxPages = 5,
    Future<void> Function()? onAddPage,
    Future<void> Function(int page)? onDeletePage,
    ValueChanged<int>? onNavigateToPage,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showPageManagerSheet(
                  context: context,
                  pages: pages,
                  grid: grid,
                  currentPage: currentPage,
                  maxPages: maxPages,
                  onAddPage: onAddPage ?? () async {},
                  onDeletePage: onDeletePage ?? (_) async {},
                  onNavigateToPage: onNavigateToPage ?? (_) {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows one card per page, empty pages labeled and non-empty ones showing a layout thumbnail', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      pages: [
        [entry(SensorType.speed)],
        [],
      ],
    );

    expect(find.text('Página 1'), findsOneWidget);
    expect(find.text('Página 2'), findsOneWidget);
    expect(find.text('Vazia'), findsOneWidget);
    expect(find.byKey(const ValueKey('pageThumbnailRect_speed')), findsOneWidget);
  });

  testWidgets('delete affordance appears on every page, empty or not, when there is more than one page', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      pages: [
        [entry(SensorType.speed)],
        [],
      ],
    );
    expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
  });

  testWidgets('delete affordance never appears when it is the only page', (tester) async {
    await pumpSheet(tester, pages: [[]]);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  testWidgets('add affordance is hidden once maxPages is reached', (tester) async {
    await pumpSheet(tester, pages: [[], []], maxPages: 2);
    expect(find.text('Adicionar página'), findsNothing);
  });

  testWidgets('add affordance appears while below maxPages', (tester) async {
    await pumpSheet(tester, pages: [[], []], maxPages: 3);
    expect(find.text('Adicionar página'), findsOneWidget);
  });

  testWidgets('tapping a page navigates to it and closes the sheet', (tester) async {
    int? navigatedTo;
    await pumpSheet(tester, pages: [[], []], onNavigateToPage: (p) => navigatedTo = p);

    await tester.tap(find.text('Página 2'));
    await tester.pumpAndSettle();

    expect(navigatedTo, 1);
    expect(find.byType(PageManagerSheet), findsNothing);
  });

  testWidgets('adding a page invokes the callback and keeps the sheet open with a new card', (tester) async {
    var addCalls = 0;
    await pumpSheet(tester, pages: [[]], onAddPage: () async => addCalls++);

    await tester.tap(find.text('Adicionar página'));
    await tester.pumpAndSettle();

    expect(addCalls, 1);
    expect(find.byType(PageManagerSheet), findsOneWidget);
    expect(find.text('Página 2'), findsOneWidget);
  });

  testWidgets('deleting an empty page invokes the callback and removes its card without closing', (tester) async {
    int? deletedPage;
    await pumpSheet(
      tester,
      pages: [
        [entry(SensorType.speed)],
        [],
      ],
      onDeletePage: (p) async => deletedPage = p,
    );

    await tester.tap(find.byIcon(Icons.delete_outline).last);
    await tester.pumpAndSettle();

    expect(deletedPage, 1);
    expect(find.byType(PageManagerSheet), findsOneWidget);
    expect(find.text('Página 2'), findsNothing);
  });

  testWidgets('deleting a non-empty page asks for confirmation first, without calling back yet', (tester) async {
    int? deletedPage;
    await pumpSheet(
      tester,
      pages: [
        [entry(SensorType.speed)],
        [],
      ],
      onDeletePage: (p) async => deletedPage = p,
    );

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(deletedPage, isNull);
  });

  testWidgets('canceling the confirmation keeps the non-empty page untouched', (tester) async {
    int? deletedPage;
    await pumpSheet(
      tester,
      pages: [
        [entry(SensorType.speed)],
        [],
      ],
      onDeletePage: (p) async => deletedPage = p,
    );

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(deletedPage, isNull);
    expect(find.text('Página 1'), findsOneWidget);
    expect(find.text('Página 2'), findsOneWidget);
  });

  testWidgets('confirming deletion of a non-empty page invokes the callback and removes its card', (tester) async {
    int? deletedPage;
    await pumpSheet(
      tester,
      pages: [
        [entry(SensorType.speed)],
        [],
      ],
      onDeletePage: (p) async => deletedPage = p,
    );

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Excluir'));
    await tester.pumpAndSettle();

    expect(deletedPage, 0);
    expect(find.byType(PageManagerSheet), findsOneWidget);
    expect(find.text('Página 2'), findsNothing);
  });

  testWidgets('deleting an empty page never shows a confirmation dialog', (tester) async {
    await pumpSheet(
      tester,
      pages: [
        [entry(SensorType.speed)],
        [],
      ],
    );

    await tester.tap(find.byIcon(Icons.delete_outline).last);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(PageManagerSheet), findsOneWidget);
  });

  testWidgets('the close button dismisses the sheet', (tester) async {
    await pumpSheet(tester, pages: [[]]);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.byType(PageManagerSheet), findsNothing);
  });
}
