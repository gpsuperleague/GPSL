const firebaseConfig = {
  apiKey: "AIzaSyD1bGkjhR5QHYjlOZ4DPADMir_-W8O6Qsk"",
  authDomain: "gpsl-31bb8.firebaseapp.com",
  projectId: "gpsl-31bb8",
  storageBucket: "gpsl-31bb8.firebasestorage.app",
  messagingSenderId: "313840138087",
  appId: "1:313840138087:web:8134a9fc396247dd7421c2"
};

firebase.initializeApp(firebaseConfig);

const auth = firebase.auth();
const db = firebase.firestore();
