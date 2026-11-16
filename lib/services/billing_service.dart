import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../services/api_service.dart';
// import '../models/models.dart';

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
  Function(bool)? _onProStatusChanged;

  /// Returns localized price string directly from Google Play Store or default fallback
  String get formattedPrice => proProduct?.price ?? '₹49 / month';

  /// Initialize early in app lifecycle (AppProvider / main)
  Future<void> initialize({Function(bool)? onProStatusChanged}) async {
    _onProStatusChanged = onProStatusChanged;

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

    // Subscribe to continuous purchase updates
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

  /// Trigger live Google Play purchase flow
  Future<bool> buyProSubscription() async {
    if (!isAvailable) {
      errorMessage = 'Google Play Store billing is not available on this device.';
      notifyListeners();
      return false;
    }

    if (proProduct == null) {
      await queryProducts();
    }

    if (proProduct == null) {
      if (errorMessage == null || errorMessage!.isEmpty) {
        errorMessage = 'Subscription product "$proSubscriptionId" details not returned by Google Play.';
      }
      notifyListeners();
      return false;
    }

    isProcessing = true;
    errorMessage = null;
    notifyListeners();

    try {
      final PurchaseParam purchaseParam = PurchaseParam(productDetails: proProduct!);
      final bool success = await _iap.buyNonConsumable(purchaseParam: purchaseParam).timeout(
        const Duration(seconds: 8),
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

  /// Handle incoming transactions from Google Play
  void _handlePurchaseUpdates(List<PurchaseDetails> purchaseDetailsList) async {
    for (var purchase in purchaseDetailsList) {
      if (purchase.productID == proSubscriptionId) {
        switch (purchase.status) {
          case PurchaseStatus.purchased:
          case PurchaseStatus.restored:
            isProcessing = false;
            
            // Verify purchase with backend BEFORE granting Pro access
            await _verifyPurchaseWithBackend(purchase);
            
            // Mandatory: complete purchase with Google Play to finalize transaction
            if (purchase.pendingCompletePurchase) {
              await _iap.completePurchase(purchase);
            }
            break;
          case PurchaseStatus.error:
            isProcessing = false;
            errorMessage = purchase.error?.message ?? 'Purchase failed or was canceled.';
            if (purchase.pendingCompletePurchase) {
              await _iap.completePurchase(purchase);
            }
            break;
          case PurchaseStatus.pending:
            isProcessing = true;
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

  /// Verify purchase token with backend server
  Future<void> _verifyPurchaseWithBackend(PurchaseDetails purchase) async {
    try {
      // Extract purchase token safely from verification data
      final verificationData = purchase.verificationData;
      String? purchaseToken;
      
      if (verificationData.serverVerificationData.isNotEmpty) {
        try {
          final serverData = jsonDecode(verificationData.serverVerificationData);
          if (serverData is Map) {
            purchaseToken = serverData['purchaseToken']?.toString() ?? serverData['token']?.toString();
          }
        } catch (_) {
          // It's a raw token string
          purchaseToken = verificationData.serverVerificationData;
        }
      }
      
      // Fallback: use local verification data if server data not available
      purchaseToken ??= verificationData.localVerificationData;

      if (purchaseToken.isEmpty) {
        if (kDebugMode) {
          print('[BILLING SERVICE] No purchase token available for verification');
        }
        errorMessage = 'Purchase verification failed: Missing purchase token';
        notifyListeners();
        return;
      }

      if (kDebugMode) {
        print('[BILLING SERVICE] Verifying purchase token with backend...');
      }

      // Call backend verification endpoint
      final token = await ApiService.getSessionToken();
      final uid = await ApiService.getEffectiveUserUuid();
      
      if (token == null || uid == null) {
        errorMessage = 'Authentication required for purchase verification';
        notifyListeners();
        return;
      }

      // Use Vercel-compatible endpoint with fallback routing like ApiService
      final endpoints = [
        '/api/v1/subscriptions/google/verify',
        '/subscriptions/google/verify',
        '/subscription/google/verify',
      ];
      
      http.Response? response;
      for (final ep in endpoints) {
        try {
          response = await http.post(
            Uri.parse('${ApiService.baseUrl}$ep'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
              'x-user-id': uid,
            },
            body: jsonEncode({
              'purchaseToken': purchaseToken,
              'productId': proSubscriptionId,
            }),
          ).timeout(const Duration(seconds: 15));
          
          if (response.statusCode != 404) break;
        } catch (_) {}
      }
      
      // If backend verification endpoint is 404 or unreachable, fallback to standard upgrade
      if (response == null || response.statusCode == 404) {
        if (kDebugMode) {
          print('[BILLING SERVICE] Verification endpoint 404/unreachable. Upgrading via ApiService fallback...');
        }
        final upgradeRes = await ApiService.upgradeSubscription(provider: 'GOOGLE_PLAY');
        if (upgradeRes['isPro'] == true || upgradeRes['success'] == true) {
          if (kDebugMode) {
            print('[BILLING SERVICE] Fallback upgrade confirmed Pro');
          }
          if (_onProStatusChanged != null) {
            _onProStatusChanged!(true);
          }
          notifyListeners();
          return;
        }
        errorMessage = 'Unable to reach verification server';
        notifyListeners();
        return;
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          if (kDebugMode) {
            print('[BILLING SERVICE] Purchase verified successfully with backend');
          }
          // Only grant Pro access AFTER backend verification succeeds
          if (_onProStatusChanged != null) {
            _onProStatusChanged!(true);
          }
        } else {
          errorMessage = data['message'] ?? 'Purchase verification failed';
          if (kDebugMode) {
            print('[BILLING SERVICE] Backend verification failed: $errorMessage');
          }
        }
      } else {
        errorMessage = 'Purchase verification failed (HTTP ${response.statusCode})';
        if (kDebugMode) {
          print('[BILLING SERVICE] Backend verification HTTP error: ${response.statusCode} ${response.body}');
        }
      }
    } catch (e) {
      errorMessage = 'Purchase verification error: $e';
      if (kDebugMode) {
        print('[BILLING SERVICE] Verification exception: $e');
      }
    }
    notifyListeners();
  }

  /// Restore previous purchases (call on app start)
  Future<void> restorePurchases() async {
    if (!isAvailable) return;
    
    try {
      if (kDebugMode) {
        print('[BILLING SERVICE] Restoring previous purchases...');
      }
      
      // Google Play InAppPurchase streams restored purchases to _handlePurchaseUpdates
      await _iap.restorePurchases();
      
      // Also check backend for active subscription
      await _checkBackendSubscriptionStatus();
      
    } catch (e) {
      if (kDebugMode) {
        print('[BILLING SERVICE] Restore purchases error: $e');
      }
    }
  }

  /// Check with backend if user has active subscription
  Future<void> _checkBackendSubscriptionStatus() async {
    try {
      final token = await ApiService.getSessionToken();
      final uid = await ApiService.getEffectiveUserUuid();
      
      if (token == null || uid == null) {
        if (kDebugMode) {
          print('[BILLING SERVICE] No auth token/uid for subscription check');
        }
        return;
      }

      final endpoints = [
        '/api/v1/subscriptions/me',
        '/subscription/me',
        '/subscription',
      ];

      for (final ep in endpoints) {
        try {
          final response = await http.get(
            Uri.parse('${ApiService.baseUrl}$ep'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
              'x-user-id': uid,
            },
          ).timeout(const Duration(seconds: 8));

          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            final subscription = data['subscription'] ?? data;
            final plan = subscription['plan']?.toString().toLowerCase();
            final status = subscription['status']?.toString().toLowerCase();
            
            if ((plan == 'pro' || plan == 'premium') && status == 'active') {
              if (kDebugMode) {
                print('[BILLING SERVICE] Backend shows active Pro subscription');
              }
              if (_onProStatusChanged != null) {
                _onProStatusChanged!(true);
              }
              return;
            }
          }
        } catch (_) {}
      }

      // Also check through ApiService direct fallback
      final sub = await ApiService.fetchUserSubscription();
      if (sub != null && sub.isActive && (sub.plan.toLowerCase() == 'pro' || sub.plan.toLowerCase() == 'premium')) {
        if (kDebugMode) {
          print('[BILLING SERVICE] ApiService confirmed active Pro subscription');
        }
        if (_onProStatusChanged != null) {
          _onProStatusChanged!(true);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('[BILLING SERVICE] Backend subscription check failed: $e');
      }
    }
  }

  @override
  void dispose() {
    _purchaseSubscription?.cancel();
    super.dispose();
  }
}
