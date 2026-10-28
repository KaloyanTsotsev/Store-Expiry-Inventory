import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

import '../services/pocketbase_service.dart';
import '../services/product_catalog_service.dart';
import 'product_form_screen.dart';

class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key, this.catalog, this.loader});
  final ProductCatalogService? catalog;
  final Future<List<RecordModel>> Function()? loader;

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  final searchController = TextEditingController();

  List<RecordModel> products = [];
  late final catalog = widget.catalog ?? ProductCatalogService();
  CatalogAccess access = const CatalogAccess(
    available: false,
    message: 'Проверява се Catalog V3…',
  );
  bool isLoading = false;
  bool isOpeningForm = false;
  String? errorMessage;

  @override
  void initState() {
    super.initState();
    loadProducts();
  }

  Future<void> loadProducts() async {
    if (isLoading) return;
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final capability = await catalog.probe();
      if (!mounted) return;
      setState(() => access = capability);
      final records =
          await (widget.loader?.call() ?? PocketBaseService.getProducts());

      if (!mounted) return;

      setState(() {
        products = records;
      });
    } catch (e) {
      PocketBaseService.logError('products.getFullList', e);
      if (!mounted) return;

      setState(() {
        errorMessage =
            'Неуспешно зареждане на продуктите.\n'
            '${PocketBaseService.errorMessage(e)}';
      });
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  Future<void> openProductForm([RecordModel? product]) async {
    if (isOpeningForm) return;
    setState(() => isOpeningForm = true);
    try {
      final created = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => ProductFormScreen(
            product: product,
            products: products,
            catalog: catalog,
            catalogAccess: access,
          ),
        ),
      );

      if (created == true && mounted) {
        await loadProducts();
      }
    } finally {
      if (mounted) setState(() => isOpeningForm = false);
    }
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = searchController.text.trim().toLowerCase();

    final filteredProducts = products.where((product) {
      final name = product.data['name']?.toString().toLowerCase() ?? '';
      final barcode = product.data['barcode']?.toString().toLowerCase() ?? '';

      final aliases = (product.data['aliases'] as List? ?? [])
          .join(' ')
          .toLowerCase();
      final codes = (product.data['supplier_identifiers'] as List? ?? [])
          .join(' ')
          .toLowerCase();
      return name.contains(query) ||
          barcode.contains(query) ||
          aliases.contains(query) ||
          codes.contains(query);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Продукти'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Обнови',
            onPressed: isLoading ? null : loadProducts,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed:
            isOpeningForm || isLoading || !access.available || !access.canCreate
            ? null
            : () => openProductForm(),
        icon: const Icon(Icons.add),
        label: const Text('Нов продукт'),
      ),
      body: Column(
        children: [
          if (!access.available || !access.canCreate)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(access.message),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: searchController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Търси име или баркод',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),

          if (!isLoading && errorMessage == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Намерени продукти: ${filteredProducts.length}',
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
            ),

          Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: loadProducts,
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 100),
                      itemCount:
                          errorMessage != null || filteredProducts.isEmpty
                          ? 1
                          : filteredProducts.length,
                      itemBuilder: (context, index) {
                        if (errorMessage != null) {
                          return Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              children: [
                                SelectableText(errorMessage!),
                                const SizedBox(height: 12),
                                FilledButton(
                                  onPressed: loadProducts,
                                  child: const Text('Опитай отново'),
                                ),
                              ],
                            ),
                          );
                        }
                        if (filteredProducts.isEmpty) {
                          return Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              query.isNotEmpty
                                  ? 'Няма продукти за това търсене.'
                                  : 'Няма достъпни продукти. Добавете първия продукт. '
                                        'Ако очаквате съществуващи записи, '
                                        'свържете се с администратора.',
                              textAlign: TextAlign.center,
                            ),
                          );
                        }
                        final product = filteredProducts[index];

                        final name =
                            product.data['name']?.toString() ?? 'Без име';

                        final barcode =
                            product.data['barcode']?.toString() ?? '';

                        final category =
                            product.data['category']?.toString() ?? '';

                        final active = product.data['active'] == true;

                        return Card(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 5,
                          ),
                          child: ListTile(
                            leading: const CircleAvatar(
                              child: Icon(Icons.inventory_2_outlined),
                            ),
                            title: Text(name),
                            onTap: isOpeningForm
                                ? null
                                : () => openProductForm(product),
                            trailing: const Icon(Icons.chevron_right),
                            subtitle: Text(
                              [
                                if (barcode.isNotEmpty) 'Баркод: $barcode',
                                if (category.isNotEmpty) category,
                                if (!active) 'Неактивен',
                              ].join('\n'),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
