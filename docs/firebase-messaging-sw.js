importScripts('https://www.gstatic.com/firebasejs/10.12.5/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.12.5/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: "AIzaSyA33ce6Ny6rNaEcZjZn8KNDnYhyBRh_6iQ",
  authDomain: "penguin-store-b4a7e.firebaseapp.com",
  projectId: "penguin-store-b4a7e",
  storageBucket: "penguin-store-b4a7e.firebasestorage.app",
  messagingSenderId: "810901848963",
  appId: "1:810901848963:web:54fda2f8b2d5baad34ecb6",
});

firebase.messaging();