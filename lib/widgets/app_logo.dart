import 'package:flutter/material.dart';

class AppLogoWidget extends StatelessWidget {
  final double size;
  final double borderRadius;
  final EdgeInsetsGeometry? margin;

  const AppLogoWidget({
    super.key,
    this.size = 90,
    this.borderRadius = 22,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: size,
      height: size,
      margin: margin ?? const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.35 : 0.12),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Image.asset(
          'assets/images/wrindha_logo.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => Image.asset(
            'assets/images/logo.png',
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (context, error2, stackTrace2) => Image.asset(
              'assets/images/wrindha_logo.jpg',
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (context, error3, stackTrace3) => Image.asset(
                'assets/images/wrindha_logo.png.jpeg',
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (context, error4, stackTrace4) => Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF060B1E),
                    borderRadius: BorderRadius.circular(borderRadius),
                  ),
                  child: Center(
                    child: Text(
                      'W',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: size * 0.44,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
