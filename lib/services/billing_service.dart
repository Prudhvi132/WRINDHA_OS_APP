import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

typedef OnPurchaseSuccessCallback = Future<void> Function(PurchaseDetails purchaseDetails);

/// Production-grade BillingService managing Google Play Billing for WrindhaOS Subscriptions.
/// 
/// Handles product queries, purchase streams, transaction validation, entitlement delivery,
/// and error handling.
class BillingService extends ChangeNotifier {
  static final BillingService instance = BillingService._internal();
  BillingService._internal();

  static const String proMonthlySubscriptionId = 'wrindha_pro_monthly';
  static const Set<String> _productIds = {proMonthlySubscriptionId};

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _subscription;

  bool _isAvailable = false;
  bool _isQuerying = false;
  bool _isPurchasing = false;
  String? _errorMessage;

  List<ProductDetails> _products = [];
  ProductDetails? _proMonthlyProduct;
  OnPurchaseSuccessCallback? _onPurchaseVerified;

  // Getters
  bool get isAvailable => _isAvailable;
  bool get isQuerying => _isQuerying;
  bool get isPurchasing => _isPurchasing;
  String? get errorMessage => _errorMessage;
  List<ProductDetails> get products => List.unmodifiable(_products);
  ProductDetails? get proMonthlyProduct => _proMonthlyProduct;
  String get proMonthlyPrice => _proMonthlyProduct?.price ?? '₹49/month';

  /// Initialize Google Play Billing and start listening to purchaseStream early in app lifecycle
  Future<void> initialize({OnPurchaseSuccessCallback? onVerified}) async {
    if (onVerified != null) {
      _onPurchaseVerified = onVerified;
    }

    // Subscribe to purchase stream early
    _subscription ??= _iap.purchaseStream.listen(
      _handlePurchaseUpdate,
      onDone: () => _subscription?.cancel(),
      onError: (error) {
        _errorMessage = 'Billing stream error: $error';
        _isPurchasing = false;
        notifyListeners();
      },
    );

    // Check store availability
    _isAvailable = await _iap.isAvailable();
    if (!_isAvailable) {
      _errorMessage = 'Google Play Store billing service is currently unavailable.';
      notifyListeners();
      return;
    }

    // Query product details from Google Play Store
    await queryProducts();
  }

  /// Register purchase verification callback from AppProvider/Backend
  void setPurchaseVerificationCallback(OnPurchaseSuccessCallback callback) {
    _onPurchaseVerified = callback;
  }

  /// Query Product details (wrindha_pro_monthly) from Google Play Console
  Future<void> queryProducts() async {
    if (!_isAvailable) return;

    _isQuerying = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final ProductDetailsResponse response = await _iap.queryProductDetails(_productIds);

      if (response.error != null) {
        _errorMessage = response.error!.message;
        _isQuerying = false;
        notifyListeners();
        return;
      }

      if (response.notFoundIDs.isNotEmpty) {
        debugPrint('[BillingService] Products not found: ${response.notFoundIDs}');
      }

      _products = response.productDetails;
      final match = _products.where((p) => p.id == proMonthlySubscriptionId);
      _proMonthlyProduct = match.isNotEmpty ? match.first : null;
    } catch (e) {
      _errorMessage = 'Failed to load subscription details: $e';
    } finally {
      _isQuerying = false;
      notifyListeners();
    }
  }

  /// Initiate auto-renewing subscription purchase for WrindhaOS Pro
  Future<bool> buyProMonthly() async {
    if (!_isAvailable) {
      _errorMessage = 'Store is unavailable. Please check Google Play Store connection.';
      notifyListeners();
      return false;
    }

    final product = _proMonthlyProduct;
    if (product == null) {
      // Re-query if not loaded yet
      await queryProducts();
      if (_proMonthlyProduct == null) {
        _errorMessage = 'Subscription product (wrindha_pro_monthly) is not available.';
        notifyListeners();
        return false;
      }
    }

    final targetProduct = _proMonthlyProduct!;

    _isPurchasing = true;
    _errorMessage = null;
    notifyListeners();

    try {
      late PurchaseParam purchaseParam;

      if (defaultTargetPlatform == TargetPlatform.android) {
        // Android Google Play Billing Purchase Param
        purchaseParam = GooglePlayPurchaseParam(
          productDetails: targetProduct,
        );
      } else {
        purchaseParam = PurchaseParam(productDetails: targetProduct);
      }

      // Launch Google Play Billing Purchase Sheet
      final bool success = await _iap.buyNonConsumable(purchaseParam: purchaseParam);
      if (!success) {
        _isPurchasing = false;
        _errorMessage = 'Could not initiate purchase with Google Play Store.';
        notifyListeners();
      }
      return success;
    } catch (e) {
      _isPurchasing = false;
      _errorMessage = 'Purchase error: $e';
      notifyListeners();
      return false;
    }
  }

  /// Restore previous Google Play Purchases
  Future<void> restorePurchases() async {
    if (!_isAvailable) {
      _errorMessage = 'Store is unavailable. Cannot restore purchases.';
      notifyListeners();
      return;
    }

    _isPurchasing = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _iap.restorePurchases();
    } catch (e) {
      _isPurchasing = false;
      _errorMessage = 'Restore purchases failed: $e';
      notifyListeners();
    }
  }

  /// Handle incoming transactions from purchaseStream
  Future<void> _handlePurchaseUpdate(List<PurchaseDetails> purchaseDetailsList) async {
    for (final PurchaseDetails purchaseDetails in purchaseDetailsList) {
      switch (purchaseDetails.status) {
        case PurchaseStatus.pending:
          _isPurchasing = true;
          _errorMessage = null;
          notifyListeners();
          break;

        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _verifyAndCompletePurchase(purchaseDetails);
          break;

        case PurchaseStatus.error:
          _isPurchasing = false;
          _errorMessage = purchaseDetails.error?.message ?? 'Transaction encountered an error.';
          if (purchaseDetails.pendingCompletePurchase) {
            await _iap.completePurchase(purchaseDetails);
          }
          notifyListeners();
          break;

        case PurchaseStatus.canceled:
          _isPurchasing = false;
          _errorMessage = 'Purchase was cancelled.';
          if (purchaseDetails.pendingCompletePurchase) {
            await _iap.completePurchase(purchaseDetails);
          }
          notifyListeners();
          break;
      }
    }
  }

  /// Validate transaction entitlement and invoke completePurchase()
  Future<void> _verifyAndCompletePurchase(PurchaseDetails purchaseDetails) async {
    try {
      if (_onPurchaseVerified != null) {
        await _onPurchaseVerified!(purchaseDetails);
      }

      // Complete Google Play transaction to acknowledge purchase
      if (purchaseDetails.pendingCompletePurchase) {
        await _iap.completePurchase(purchaseDetails);
      }

      _isPurchasing = false;
      _errorMessage = null;
    } catch (e) {
      _isPurchasing = false;
      _errorMessage = 'Verification failed: $e';
    } finally {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }
}
