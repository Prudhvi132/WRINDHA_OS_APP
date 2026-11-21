import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

/// Singleton Service handling live Google Play Billing for WrindhaOS
class BillingService extends ChangeNotifier {
  static final BillingService _instance = BillingService._internal();
  factory BillingService() => _instance;
  BillingService._internal();

  static const String proSubscriptionId = 'wrindha_pro_monthly';

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;

  bool isAvailable = false;
  ProductDetails? proProduct;
  bool isProcessing = false;
  String? errorMessage;
  Function(bool isPro, {String? purchaseToken, String? orderId})? _onProStatusChanged;

  /// Returns localized price string directly from Google Play Store or empty if not yet loaded
  String get formattedPrice => proProduct?.price ?? '';
  bool get hasProduct => proProduct != null;

  /// Initialize early in app lifecycle (AppProvider / main)
  Future<void> initialize({Function(bool isPro, {String? purchaseToken, String? orderId})? onProStatusChanged}) async {
    if (onProStatusChanged != null) {
      _onProStatusChanged = onProStatusChanged;
    }

    try {
      isAvailable = await _iap.isAvailable();
    } catch (e) {
      isAvailable = false;
      if (kDebugMode) {
        print('[BILLING SERVICE] Play Billing check error: $e');
      }
    }

    if (!isAvailable) {
      if (kDebugMode) {
        print('[BILLING SERVICE] Google Play Store Billing is not available on this device/environment.');
      }
      notifyListeners();
      return;
    }

    // Subscribe to continuous purchase updates across entire app lifecycle
    _purchaseSubscription?.cancel();
    _purchaseSubscription = _iap.purchaseStream.listen(
      _handlePurchaseUpdates,
      onDone: () => _purchaseSubscription?.cancel(),
      onError: (error) {
        errorMessage = error.toString();
        notifyListeners();
      },
    );

    // Load live Product Details from Google Play Store
    await queryProducts();
  }

  /// Query Google Play Store for the wrindha_pro_monthly product
  Future<void> queryProducts() async {
    try {
      isAvailable = await _iap.isAvailable().timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
    } catch (e) {
      isAvailable = false;
    }

    if (!isAvailable) {
      errorMessage = 'Google Play Store billing is unavailable on this device.';
      if (kDebugMode) {
        print('[BILLING SERVICE] Google Play Store Billing is not available on this device/environment.');
      }
      notifyListeners();
      return;
    }

    // Subscribe to continuous purchase updates if not already subscribed
    _purchaseSubscription ??= _iap.purchaseStream.listen(
      _handlePurchaseUpdates,
      onDone: () => _purchaseSubscription?.cancel(),
      onError: (error) {
        errorMessage = error.toString();
        notifyListeners();
      },
    );

    try {
      final ProductDetailsResponse response = await _iap.queryProductDetails({proSubscriptionId}).timeout(
        const Duration(seconds: 8),
        onTimeout: () => ProductDetailsResponse(
          productDetails: [],
          notFoundIDs: [proSubscriptionId],
        ),
      );
      if (response.error != null) {
        errorMessage = response.error!.message;
        if (kDebugMode) {
          print('[BILLING SERVICE] Query Product Error: ${response.error!.message}');
        }
      } else if (response.productDetails.isNotEmpty) {
        proProduct = response.productDetails.first;
        errorMessage = null;
        if (kDebugMode) {
          print('[BILLING SERVICE] Found Product: ${proProduct!.id} - Price: ${proProduct!.price}');
        }
      } else {
        errorMessage = 'Product "$proSubscriptionId" pending Play Console activation or app download via Play Store link.';
        if (kDebugMode) {
          print('[BILLING SERVICE] Product "$proSubscriptionId" not found in Google Play Console.');
        }
      }
    } catch (e) {
      errorMessage = e.toString();
      if (kDebugMode) {
        print('[BILLING SERVICE] Exception querying products: $e');
      }
    }
    notifyListeners();
  }

  /// Trigger live Google Play purchase flow with retry support
  Future<bool> buyProSubscription() async {
    if (!isAvailable) {
      errorMessage = 'Google Play Store billing is not available on this device.';
      notifyListeners();
      return false;
    }

    // Attempt initial query if product details are missing
    if (proProduct == null) {
      await queryProducts();
    }

    // Attempt one retry if still missing
    if (proProduct == null) {
      await Future.delayed(const Duration(milliseconds: 500));
      await queryProducts();
    }

    if (proProduct == null) {
      if (errorMessage == null || errorMessage!.isEmpty) {
        errorMessage = 'Subscription product "$proSubscriptionId" details not returned by Google Play. Please verify Play Store connection.';
      }
      notifyListeners();
      return false;
    }

    isProcessing = true;
    errorMessage = null;
    notifyListeners();

    try {
      late final PurchaseParam purchaseParam;

      if (defaultTargetPlatform == TargetPlatform.android && proProduct is GooglePlayProductDetails) {
        purchaseParam = GooglePlayPurchaseParam(
          productDetails: proProduct!,
          changeSubscriptionParam: null,
          applicationUserName: null,
        );
      } else {
        purchaseParam = PurchaseParam(productDetails: proProduct!);
      }

      final bool success = await _iap.buyNonConsumable(purchaseParam: purchaseParam).timeout(
        const Duration(seconds: 10),
        onTimeout: () => false,
      );

      if (!success) {
        isProcessing = false;
        errorMessage = 'Google Play Store did not launch purchase sheet (timeout or unavailable).';
        notifyListeners();
      }
      return success;
    } catch (e) {
      isProcessing = false;
      errorMessage = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Trigger Google Play restore flow for existing active subscriptions
  Future<void> restorePurchases() async {
    if (!isAvailable) {
      errorMessage = 'Google Play Store billing is not available on this device.';
      notifyListeners();
      return;
    }

    isProcessing = true;
    errorMessage = null;
    notifyListeners();

    try {
      await _iap.restorePurchases();
    } catch (e) {
      errorMessage = 'Error restoring purchases: $e';
      if (kDebugMode) {
        print('[BILLING SERVICE] Exception restoring purchases: $e');
      }
    } finally {
      isProcessing = false;
      notifyListeners();
    }
  }

  /// Handle incoming transactions from Google Play globally
  void _handlePurchaseUpdates(List<PurchaseDetails> purchaseDetailsList) async {
    for (var purchase in purchaseDetailsList) {
      if (purchase.productID == proSubscriptionId) {
        switch (purchase.status) {
          case PurchaseStatus.purchased:
          case PurchaseStatus.restored:
            isProcessing = false;
            errorMessage = null;
            final token = purchase.verificationData.serverVerificationData;
            final orderId = purchase.purchaseID;

            // Immediately notify persistent global listener to upgrade user
            if (_onProStatusChanged != null) {
              _onProStatusChanged!(true, purchaseToken: token, orderId: orderId);
            }

            // Mandatory: complete purchase with Google Play to finalize transaction & prevent 3-day refund
            if (purchase.pendingCompletePurchase) {
              await _iap.completePurchase(purchase);
            }
            break;

          case PurchaseStatus.pending:
            isProcessing = true;
            errorMessage = 'Payment is pending approval (e.g. UPI/Netbanking). Pro will unlock automatically once confirmed.';
            break;

          case PurchaseStatus.error:
            isProcessing = false;
            errorMessage = purchase.error?.message ?? 'Purchase failed or was canceled.';
            if (purchase.pendingCompletePurchase) {
              await _iap.completePurchase(purchase);
            }
            break;

          case PurchaseStatus.canceled:
            isProcessing = false;
            errorMessage = 'Purchase was canceled.';
            break;
        }
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _purchaseSubscription?.cancel();
    super.dispose();
  }
}
