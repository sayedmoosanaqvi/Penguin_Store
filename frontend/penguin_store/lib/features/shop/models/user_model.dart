class UserModel {
  final String id;
  final String email;
  final bool isAdmin; // The "Golden Key" for Admin powers

  UserModel({
    required this.id, 
    required this.email, 
    this.isAdmin = false, // Defaults to a regular customer
  });

  // Converts the JSON from your FastAPI backend into this Dart object
  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id'].toString(),
      email: json['email'],
      // Logic: If the backend sends 'is_admin' as true, grant powers
      isAdmin: json['is_admin'] ?? false, 
    );
  }

  // Useful if you need to send user data back to the server
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'is_admin': isAdmin,
    };
  }
}