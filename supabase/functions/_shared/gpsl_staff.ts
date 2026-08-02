/** True if JWT user is league admin or a granted site mod. */
export async function isGpslAdminOrMod(
  // deno-lint-ignore no-explicit-any
  userClient: { rpc: (fn: string) => Promise<{ data: unknown; error: unknown }> },
  user: { email?: string | null } | null,
  adminEmail = "rotavator66@outlook.com"
): Promise<boolean> {
  if (!user) return false;
  if ((user.email || "").toLowerCase() === adminEmail.toLowerCase()) return true;
  try {
    const { data, error } = await userClient.rpc("is_gpsl_admin_or_mod");
    if (!error && data === true) return true;
  } catch {
    /* fall through */
  }
  try {
    const { data, error } = await userClient.rpc("is_gpsl_admin");
    if (!error && data === true) return true;
  } catch {
    /* ignore */
  }
  return false;
}
