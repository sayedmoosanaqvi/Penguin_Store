import 'package:flutter/material.dart';

import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_colors.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isLogin = true; // Toggles between Login and Signup modes
  bool _isLoading = false;
  
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    bool success = false;

    if (_isLogin) {
      // Execute Login Logic
      success = await authProvider.login(
        _emailController.text.trim(),
        _passwordController.text.trim(),
      );
    } else {
      // Execute Signup Logic
      success = await authProvider.signup(
        _emailController.text.trim(),
        _passwordController.text.trim(),
      );
      
      // If signup is successful, automatically log them in!
      if (success) {
        success = await authProvider.login(
          _emailController.text.trim(),
          _passwordController.text.trim(),
        );
      }
    }

    setState(() => _isLoading = false);

    if (success) {
      // Success! Close the Auth Screen and go back to the Store
      if (mounted) Navigator.pop(context);
    } else {
      // Show Error
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isLogin ? 'Login failed. Check credentials.' : 'Signup failed. Email may already exist.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primaryBlack,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.pureWhite),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Logo or Icon
                const Icon(Icons.storefront, size: 80, color: AppColors.accentYellow),
                const SizedBox(height: 20),
                
                Text(
                  _isLogin ? 'Welcome Back' : 'Create Account',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.pureWhite, fontSize: 32, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 40),

                // Email Field
                TextFormField(
                  controller: _emailController,
                  style: const TextStyle(color: AppColors.primaryBlack),
                  decoration: InputDecoration(
                    hintText: 'Email Address',
                    filled: true,
                    fillColor: AppColors.pureWhite,
                    prefixIcon: const Icon(Icons.email_outlined, color: Colors.grey),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                  validator: (value) => value!.isEmpty || !value.contains('@') ? 'Enter a valid email' : null,
                ),
                const SizedBox(height: 16),

                // Password Field
                TextFormField(
                  controller: _passwordController,
                  obscureText: true,
                  style: const TextStyle(color: AppColors.primaryBlack),
                  decoration: InputDecoration(
                    hintText: 'Password',
                    filled: true,
                    fillColor: AppColors.pureWhite,
                    prefixIcon: const Icon(Icons.lock_outline, color: Colors.grey),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                  validator: (value) => value!.length < 6 ? 'Password must be at least 6 characters' : null,
                ),
                const SizedBox(height: 30),

                // Submit Button
                SizedBox(
                  height: 55,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accentYellow,
                      foregroundColor: AppColors.primaryBlack,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _isLoading ? null : _submit,
                    child: _isLoading
                        ? const CircularProgressIndicator(color: AppColors.primaryBlack)
                        : Text(
                            _isLogin ? 'LOG IN' : 'SIGN UP',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                          ),
                  ),
                ),
                const SizedBox(height: 20),

                // Toggle Button (Login <-> Signup)
                TextButton(
                  onPressed: () {
                    setState(() {
                      _isLogin = !_isLogin; // Flips the screen mode
                    });
                  },
                  child: Text(
                    _isLogin ? "Don't have an account? Sign Up" : "Already have an account? Log In",
                    style: TextStyle(color: Colors.grey[400]),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}