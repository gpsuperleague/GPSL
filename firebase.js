/* ============================================================
   MODULE: Firebase Initialisation
   Purpose:
   - Initialise Firebase App
   - Provide global `auth` and `db` handles
   - Used across: dashboard, admin, listings, clubs, club page
   ============================================================ */

const firebaseConfig = {
  apiKey: "AIzaSyD1bGkjhR5QHYjlOZ4DPADMir_-W8O6Qsk",
  authDomain: "gpsl-31bb8.firebaseapp.com",
  projectId: "gpsl-31bb8",
  storageBucket: "gpsl-31bb8.firebasestorage.app",
  messagingSenderId: "313840138087",
  appId: "1:313840138087:web:8134a9fc396247dd7421c2"
};

/* --------------------------------------------
   Initialise Firebase App
   -------------------------------------------- */
firebase.initializeApp(firebaseConfig);

/* --------------------------------------------
   Exported Firebase Services
   -------------------------------------------- */
const auth = firebase.auth();       // Used for login, logout, auth state
const db   = firebase.firestore();  // Used for user ShortName lookup
