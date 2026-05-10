/* ============================================================
   MODULE: Firebase + Supabase Bootstrap
   Purpose:
   - Initialise Firebase (auth + Firestore)
   - Maintain a single, global Supabase client
   - Attach Firebase ID token to Supabase requests
   - Expose: window.auth, window.db, window.supabase
   ============================================================ */

import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

/* --------------------------------------------
   Firebase Initialisation
   -------------------------------------------- */
const firebaseConfig = {
  apiKey: "AIzaSyD1bGkjhR5QHYjlOZ4DPADMir_-W8O6Qsk",
  authDomain: "gpsl-31bb8.firebaseapp.com",
  projectId: "gpsl-31bb8",
  storageBucket: "gpsl-31bb8.firebasestorage.app",
  messagingSenderId: "313840138087",
  appId: "1:313840138087:web:8134a9fc396247dd7421c2"
};

if (!firebase.apps.length) {
  firebase.initializeApp(firebaseConfig);
}

/* --------------------------------------------
   Exported Firebase Services
   -------------------------------------------- */
const auth = firebase.auth();
const db   = firebase.firestore();

/* --------------------------------------------
   Supabase Client (JWT‑aware)
   -------------------------------------------- */
const SUPABASE_URL = "https://omyyogfumrjoaweuawjn.supabase.co";
const SUPABASE_ANON_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9teXlvZ2Z1bXJqb2F3ZXVhd2puIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ5NTUxMzUsImV4cCI6MjA5MDUzMTEzNX0.7UVkpi4DOtC9VNjFLnE_ZnK6vhDtlfesZ_8rfnrkno4";

let supabase = null;

function buildSupabaseClient(idToken = null) {
  return createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: {
      headers: idToken
        ? { Authorization: `Bearer ${idToken}` }
        : {}
    }
  });
}

/* --------------------------------------------
   Initial anonymous client (before login)
   -------------------------------------------- */
supabase = buildSupabaseClient(null);

/* --------------------------------------------
   Keep Supabase in sync with Firebase auth
   -------------------------------------------- */
auth.onIdTokenChanged(async user => {
  if (!user) {
    // Logged out → fall back to anonymous client
    supabase = buildSupabaseClient(null);
    window.supabase = supabase;
    return;
  }

  try {
    const token = await user.getIdToken(/* forceRefresh */ true);
    supabase = buildSupabaseClient(token);
    window.supabase = supabase;
  } catch (err) {
    console.error("Failed to refresh Firebase ID token for Supabase:", err);
    supabase = buildSupabaseClient(null);
    window.supabase = supabase;
  }
});

/* --------------------------------------------
   Expose globals for all pages/modules
   -------------------------------------------- */
window.auth = auth;
window.db = db;
window.supabase = supabase;
