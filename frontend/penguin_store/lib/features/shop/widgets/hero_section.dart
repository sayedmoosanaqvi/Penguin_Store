// import 'package:flutter/material.dart';
// import '../../../core/theme/app_colors.dart';
// import '../../../core/responsive/responsive_layout.dart';

// class HeroSection extends StatelessWidget {
//   const HeroSection({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return Container(
//       width: double.infinity,
//       color: AppColors.primaryBlack,
//       padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 60),
//       child: ResponsiveLayout(
//         mobile: Column(
//           children: [
//             _buildTextContent(isMobile: true),
//             const SizedBox(height: 40),
//             _buildImageCollage(),
//           ],
//         ),
//         desktop: Row(
//           crossAxisAlignment: CrossAxisAlignment.center,
//           children: [
//             Expanded(flex: 1, child: _buildTextContent(isMobile: false)),
//             const SizedBox(width: 40),
//             Expanded(flex: 1, child: _buildImageCollage()),
//           ],
//         ),
//       ),
//     );
//   }

//   // LEFT SIDE: Text and Buttons (Fixed Alignment)
//   Widget _buildTextContent({required bool isMobile}) {
//     return Column(
//       crossAxisAlignment: isMobile ? CrossAxisAlignment.center : CrossAxisAlignment.start,
//       children: [
//         // 1. AI Badge
//         Container(
//           padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
//           decoration: BoxDecoration(
//             color: Colors.transparent,
//             border: Border.all(color: AppColors.accentYellow.withOpacity(0.3)),
//             borderRadius: BorderRadius.circular(20),
//           ),
//           child: Row(
//             mainAxisSize: MainAxisSize.min,
//             children: const [
//               Icon(Icons.auto_awesome, color: AppColors.accentYellow, size: 14),
//               SizedBox(width: 8),
//               Text(
//                 'AI-POWERED SHOPPING',
//                 style: TextStyle(color: AppColors.accentYellow, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1),
//               ),
//             ],
//           ),
//         ),
//         const SizedBox(height: 24),

//         // 2. Main Headline
//         RichText(
//           textAlign: isMobile ? TextAlign.center : TextAlign.left,
//           text: TextSpan(
//             style: TextStyle(
//               fontSize: isMobile ? 48 : 64, 
//               fontWeight: FontWeight.w900, 
//               color: AppColors.pureWhite, 
//               height: 1.1,
//             ),
//             children: const [
//               TextSpan(text: 'Welcome to\n'),
//               TextSpan(text: 'Penguin\n', style: TextStyle(color: AppColors.accentYellow)),
//               TextSpan(text: 'Store 🐧'),
//             ],
//           ),
//         ),
//         const SizedBox(height: 20),

//         // 3. Subtext
//         Text(
//           'Smart shopping with AI recommendations, instant\nsupport, and the best deals — all in one place.',
//           style: TextStyle(color: Colors.grey[400], fontSize: 16, height: 1.5),
//           textAlign: isMobile ? TextAlign.center : TextAlign.left,
//         ),
//         const SizedBox(height: 40),

//         // 4. Buttons
//         Wrap(
//           spacing: 16,
//           runSpacing: 16,
//           alignment: isMobile ? WrapAlignment.center : WrapAlignment.start,
//           children: [
//             ElevatedButton(
//               onPressed: () {},
//               style: ElevatedButton.styleFrom(
//                 backgroundColor: AppColors.accentYellow,
//                 foregroundColor: AppColors.primaryBlack,
//                 padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
//                 shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
//               ),
//               child: Row(
//                 mainAxisSize: MainAxisSize.min,
//                 children: const [
//                   Text('SHOP NOW', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
//                   SizedBox(width: 8),
//                   Icon(Icons.arrow_forward, size: 18),
//                 ],
//               ),
//             ),
            
//             ElevatedButton(
//               onPressed: () {},
//               style: ElevatedButton.styleFrom(
//                 backgroundColor: Colors.grey[900], 
//                 foregroundColor: AppColors.pureWhite,
//                 padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
//                 shape: RoundedRectangleBorder(
//                   borderRadius: BorderRadius.circular(12),
//                   side: BorderSide(color: Colors.grey[800]!),
//                 ),
//               ),
//               child: Row(
//                 mainAxisSize: MainAxisSize.min,
//                 children: const [
//                   Icon(Icons.auto_awesome, color: AppColors.accentYellow, size: 18),
//                   SizedBox(width: 8),
//                   Text('ASK AI', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
//                 ],
//               ),
//             ),
//           ],
//         )
//       ],
//     );
//   }

//   // RIGHT SIDE: The Staggered Image Collage
//   Widget _buildImageCollage() {
//     return SizedBox(
//       height: 500, 
//       child: Row(
//         children: [
//           Expanded(
//             child: Column(
//               children: [
//                 Expanded(flex: 3, child: _collageImage('https://images.unsplash.com/photo-1523275335684-37898b6baf30?auto=format&fit=crop&w=600&q=80')),
//                 const SizedBox(height: 16),
//                 Expanded(flex: 2, child: _collageImage('https://images.unsplash.com/photo-1505740420928-5e560c06d30e?auto=format&fit=crop&w=600&q=80')),
//               ],
//             ),
//           ),
//           const SizedBox(width: 16),
//           Expanded(
//             child: Column(
//               children: [
//                 Expanded(flex: 2, child: _collageImage('https://images.unsplash.com/photo-1542291026-7eec264c27ff?auto=format&fit=crop&w=600&q=80')),
//                 const SizedBox(height: 16),
//                 Expanded(flex: 3, child: _collageImage('https://images.unsplash.com/photo-1553062407-98eeb64c6a62?auto=format&fit=crop&w=600&q=80')),
//               ],
//             ),
//           ),
//         ],
//       ),
//     );
//   }

//   Widget _collageImage(String url) {
//     return Container(
//       decoration: BoxDecoration(
//         borderRadius: BorderRadius.circular(16),
//         image: DecorationImage(image: NetworkImage(url), fit: BoxFit.cover),
//       ),
//     );
//   }
// }
