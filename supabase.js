import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm';

window.supabase = createClient(
  'https://omyyogfumrjoaweuawjn.supabase.co',
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9teXlvZ2Z1bXJqb2F3ZXVhd2puIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ5NTUxMzUsImV4cCI6MjA5MDUzMTEzNX0.7UVkpi4DOtC9VNjFLnE_ZnK6vhDtlfesZ_8rfnrkno4'
);

document.addEventListener("DOMContentLoaded", async () => {
  const hash = window.location.hash;

  // Detect password recovery link
  if (hash.includes("type=recovery")) {
    const newPassword = prompt("Enter your new password");

    if (newPassword) {
      const { data, error } = await supabase.auth.updateUser({
        password: newPassword
      });

      if (error) {
        alert("Error updating password: " + error.message);
      } else {
        alert("Password updated successfully. Please log in.");
        window.location.href = "login.html"; // or your login page
      }
    }
  }
});
