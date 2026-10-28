import 'package:flutter/material.dart';

const storeFlowSubtitle = 'Умно управление на доставки и срокове на годност';
const storeFlowTagline = 'Доставки, наличности и срокове — на едно място.';
const storeFlowDescription =
    'StoreFlow — Сканирай стокови разписки, разпознавай продуктите автоматично и управлявай складовите наличности, партидите и сроковете на годност — бързо, лесно и точно.';

class StoreFlowBrand extends StatelessWidget {
  const StoreFlowBrand({super.key});
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F7F6),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Image.asset(
          'assets/branding/storeflow-symbol.png',
          width: 88,
          height: 88,
          semanticLabel: 'Символ StoreFlow',
          fit: BoxFit.contain,
        ),
      ),
      const SizedBox(height: 16),
      Text(
        'StoreFlow',
        style: Theme.of(context).textTheme.headlineLarge
            ?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 8),
      const Text(storeFlowSubtitle, textAlign: TextAlign.center),
    ],
  );
}
