/** Fixed owner feedback survey questions (keys must match owner_feedback_rating_keys() in SQL). */
export const FEEDBACK_RATINGS = [
  { key: "overall", label: "Overall enjoyment of GPSL", hint: "How much are you enjoying being an owner?", required: true },
  { key: "auctions", label: "Auctions & drafts", hint: "Player draft, manager auction, club auction, transfer market" },
  { key: "matchday", label: "Match day", hint: "Squad selection, check-in, playing and reporting results" },
  { key: "scheduling", label: "Arranging fixtures", hint: "Proposing kick-offs, deadlines, the schedule page" },
  { key: "finances", label: "Finances", hint: "Budgets, wages, sponsorship, prize money, loans" },
  { key: "scouting", label: "Scouting & squad planning", hint: "Target lists, tactic boards, squad rules" },
  { key: "website", label: "Website ease of use", hint: "Finding things, menus, speed, works on your device" },
  { key: "communication", label: "Communication", hint: "Inbox messages, Discord, admin updates" },
  { key: "rules", label: "Rules — clarity & fairness", hint: "Easy to understand, applied fairly" },
];

export const FEEDBACK_TEXTS = [
  { key: "liked", label: "What's working well?", hint: "Features or moments you enjoy most." },
  { key: "frustrations", label: "What frustrates you, or what would you fix first?", hint: "Anything confusing, slow or unfair." },
  {
    key: "recommendation",
    label: "Your recommendations",
    hint: "Ideas, new features, rule changes — anything you'd like to see in GPSL.",
    big: true,
  },
];
