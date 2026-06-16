// ===============================
// SUPABASE_CLIENT.JS
// ===============================

import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

export const supabase = createClient(
  "https://omyyogfumrjoaweuawjn.supabase.co",
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9teXlvZ2Z1bXJqb2F3ZXVhd2puIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ5NTUxMzUsImV4cCI6MjA5MDUzMTEzNX0.7UVkpi4DOtC9VNjFLnE_ZnK6vhDtlfesZ_8rfnrkno4"
);

window.supabase = supabase;

/**
 * Safari/iOS: read session from storage first. getUser() alone can return null
 * briefly right after login redirect while localStorage is still settling.
 */
export async function getAuthUser() {
  const { data: sessionData } = await supabase.auth.getSession();
  if (sessionData?.session?.user) return sessionData.session.user;

  const { data: userData } = await supabase.auth.getUser();
  return userData?.user ?? null;
}

/** After signInWithPassword — confirm session persisted before navigating (iOS). */
export async function waitForAuthSession(maxAttempts = 8) {
  for (let i = 0; i < maxAttempts; i += 1) {
    const { data } = await supabase.auth.getSession();
    if (data?.session?.user) return data.session;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return null;
}
