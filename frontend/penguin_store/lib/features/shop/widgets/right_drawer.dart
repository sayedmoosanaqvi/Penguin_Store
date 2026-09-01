import 'package:flutter/material.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/screens/auth_screen.dart';
import 'package:provider/provider.dart'; // Need this for state management
import '../screens/admin_screen.dart';
// Your Auth Engine
// The Login Screen we just built

class RightDrawer extends StatelessWidget {
  const RightDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    // 1. This grabs the Auth state to check if someone is logged in
    final authData = Provider.of<AuthProvider>(context);
    // Grab the dynamic theme
    final theme = Theme.of(context);

    return Drawer(
      backgroundColor: theme.scaffoldBackgroundColor,
      child: Column(
        children: [
          // 2. Dynamic User Account Header
          UserAccountsDrawerHeader(
            decoration: BoxDecoration(color: theme.cardTheme.color ?? theme.colorScheme.surface),
            currentAccountPicture: CircleAvatar(
              backgroundColor: theme.primaryColor,
              child: Text('M', style: TextStyle(color: theme.scaffoldBackgroundColor, fontWeight: FontWeight.bold, fontSize: 24)),
            ),
            accountName: Text(
              authData.isAuthenticated ? 'Welcome Back!' : 'Guest User', 
              style: TextStyle(color: theme.textTheme.titleMedium?.color, fontWeight: FontWeight.bold)
            ),
            accountEmail: Text(
              authData.userEmail ?? 'Please log in to manage your cart', 
              style: TextStyle(color: theme.textTheme.bodySmall?.color ?? Colors.grey[400])
            ),
          ),
          
          // 3. Navigation Options
          _buildDrawerTile(Icons.home_outlined, 'Home', () => Navigator.pop(context), theme),
          _buildDrawerTile(Icons.person_outline, 'My Profile', () {}, theme),
          _buildDrawerTile(Icons.shopping_bag_outlined, 'My Orders', () {}, theme),
          
          const Divider(color: Colors.grey, indent: 20, endIndent: 20),
          
          // 4. THE ADMIN SECURITY GATE
          // This only draws the button on the screen if the JWT token says 'isAdmin = true'
          if (authData.isAdmin)
            _buildDrawerTile(Icons.admin_panel_settings_outlined, 'Admin Panel', () {
              Navigator.pop(context); // Close Drawer
              Navigator.push(context, MaterialPageRoute(builder: (context) => const AdminScreen()));
            }, theme),
          
          const Spacer(),
          
          // 5. CORRECTED LOGIN/LOGOUT TOGGLE
          if (authData.isAuthenticated)
            _buildDrawerTile(Icons.logout, 'Logout', () {
              authData.logout(); // Tell the provider to clear the token
              Navigator.pop(context); // Close the drawer
            }, theme, isDanger: true)
          else
            _buildDrawerTile(Icons.login, 'Log In', () {
              Navigator.pop(context); // Close the drawer
              Navigator.push(
                context, 
                MaterialPageRoute(builder: (context) => const AuthScreen())
              );
            }, theme),
            
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  // Helper Widget
  Widget _buildDrawerTile(IconData icon, String title, VoidCallback onTap, ThemeData theme, {bool isDanger = false}) {
    return ListTile(
      leading: Icon(icon, color: isDanger ? Colors.redAccent : theme.primaryColor),
      title: Text(
        title, 
        style: TextStyle(color: isDanger ? Colors.redAccent : theme.textTheme.bodyLarge?.color, fontSize: 16)
      ),
      onTap: onTap,
    );
  }
}