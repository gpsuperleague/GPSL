import {
  Callout,
  Card,
  CardBody,
  CardHeader,
  Divider,
  Grid,
  H1,
  H2,
  H3,
  Pill,
  Row,
  Stack,
  Stat,
  Table,
  Text,
  computeDAGLayout,
  useHostTheme,
  useMemo,
  useState,
} from "cursor/canvas";

type TabId =
  | "flow"
  | "playnow"
  | "attempts"
  | "options"
  | "deadlines"
  | "penalties"
  | "miss";

const TABS: { id: TabId; label: string }[] = [
  { id: "flow", label: "Full flow" },
  { id: "playnow", label: "Play now" },
  { id: "attempts", label: "Attempts 1–3" },
  { id: "options", label: "Owner options" },
  { id: "deadlines", label: "Deadlines" },
  { id: "penalties", label: "Penalties" },
  { id: "miss", label: "After check-in miss" },
];

type NodeMeta = {
  id: string;
  label: string;
  detail: string;
  kind: "start" | "step" | "gate" | "fine" | "ok" | "side";
};

const FLOW_NODES: NodeMeta[] = [
  {
    id: "start",
    label: "Fixture live",
    detail: "League / cup match row",
    kind: "start",
  },
  {
    id: "unsch",
    label: "Unscheduled",
    detail: "Home proposes · poke · compromise",
    kind: "step",
  },
  {
    id: "neg",
    label: "Negotiating",
    detail: "Accept / Counter / Discord lock",
    kind: "step",
  },
  {
    id: "agreed",
    label: "Agreed KO",
    detail: "Future kick-off locked",
    kind: "ok",
  },
  {
    id: "playnow",
    label: "Play now",
    detail: "Both press · 20-min session · KO suspend",
    kind: "side",
  },
  {
    id: "bring",
    label: "Bring KO forward",
    detail: "Earlier UK 10-min · opponent confirms",
    kind: "side",
  },
  {
    id: "checkin",
    label: "Check-in",
    detail: "Normal ±10 · or during Play now",
    kind: "gate",
  },
  {
    id: "play",
    label: "Match Day",
    detail: "Both in → submit result",
    kind: "step",
  },
  {
    id: "miss",
    label: "Miss path",
    detail: "Fine ladder · enter result OR reset",
    kind: "fine",
  },
  {
    id: "done",
    label: "Played",
    detail: "Confirm + stats",
    kind: "ok",
  },
];

const FLOW_EDGES: Array<{ from: string; to: string; label?: string }> = [
  { from: "start", to: "unsch" },
  { from: "unsch", to: "neg" },
  { from: "neg", to: "agreed", label: "accept" },
  { from: "agreed", to: "playnow" },
  { from: "agreed", to: "bring" },
  { from: "agreed", to: "checkin", label: "wait / KO" },
  { from: "playnow", to: "checkin", label: "both ready" },
  { from: "bring", to: "agreed", label: "confirm" },
  { from: "checkin", to: "play", label: "both in" },
  { from: "checkin", to: "miss", label: "miss" },
  { from: "miss", to: "play", label: "enter result" },
  { from: "miss", to: "unsch", label: "reset" },
  { from: "play", to: "done" },
];

function FlowChart() {
  const theme = useHostTheme();
  const t = theme.tokens;
  const nodeW = 210;
  const nodeH = 52;

  const layout = useMemo(
    () =>
      computeDAGLayout({
        nodes: FLOW_NODES.map((n) => ({ id: n.id })),
        edges: FLOW_EDGES.map((e) => ({ from: e.from, to: e.to })),
        direction: "vertical",
        nodeWidth: nodeW,
        nodeHeight: nodeH,
        rankGap: 44,
        nodeGap: 28,
        padding: 12,
      }),
    []
  );

  const byId = useMemo(() => new Map(FLOW_NODES.map((n) => [n.id, n])), []);
  const edgeLabel = useMemo(() => {
    const m = new Map<string, string>();
    for (const e of FLOW_EDGES) {
      if (e.label) m.set(`${e.from}->${e.to}`, e.label);
    }
    return m;
  }, []);

  function strokeFor(kind: NodeMeta["kind"]): string {
    switch (kind) {
      case "start":
        return t.accent.primary;
      case "fine":
        return t.category.yellow;
      case "ok":
        return t.category.green;
      case "gate":
        return t.category.orange;
      case "side":
        return t.accent.primary;
      default:
        return t.stroke.primary;
    }
  }

  return (
    <div style={{ overflowX: "auto" }}>
      <svg
        width={layout.width}
        height={layout.height}
        viewBox={`0 0 ${layout.width} ${layout.height}`}
        role="img"
        aria-label="Match-making lifecycle flowchart"
      >
        {layout.edges.map((e, i) => {
          const lbl = edgeLabel.get(`${e.from}->${e.to}`);
          const midX = (e.sourceX + e.targetX) / 2;
          const midY = (e.sourceY + e.targetY) / 2;
          return (
            <g key={`${e.from}-${e.to}-${i}`}>
              <line
                x1={e.sourceX}
                y1={e.sourceY}
                x2={e.targetX}
                y2={e.targetY}
                stroke={t.stroke.secondary}
                strokeWidth={1.5}
                strokeDasharray={e.isBackEdge ? "4 3" : undefined}
              />
              {lbl ? (
                <text
                  x={midX + 8}
                  y={midY + 4}
                  fill={t.text.secondary}
                  fontSize={11}
                >
                  {lbl}
                </text>
              ) : null}
            </g>
          );
        })}
        {layout.nodes.map((n) => {
          const meta = byId.get(n.id)!;
          return (
            <g key={n.id} transform={`translate(${n.x}, ${n.y})`}>
              <rect
                width={nodeW}
                height={nodeH}
                rx={6}
                fill={t.fill.secondary}
                stroke={strokeFor(meta.kind)}
                strokeWidth={meta.kind === "start" ? 2 : 1}
              />
              <text
                x={12}
                y={22}
                fill={t.text.primary}
                fontSize={12}
                fontWeight={600}
              >
                {meta.label}
              </text>
              <text x={12} y={40} fill={t.text.secondary} fontSize={10}>
                {meta.detail.length > 36
                  ? meta.detail.slice(0, 34) + "…"
                  : meta.detail}
              </text>
            </g>
          );
        })}
      </svg>
    </div>
  );
}

function TabBar({
  active,
  onChange,
}: {
  active: TabId;
  onChange: (id: TabId) => void;
}) {
  return (
    <Row gap={8} style={{ flexWrap: "wrap" }}>
      {TABS.map((t) => (
        <Pill
          key={t.id}
          active={active === t.id}
          onClick={() => onChange(t.id)}
          tone="neutral"
        >
          {t.label}
        </Pill>
      ))}
    </Row>
  );
}

function FlowTab() {
  return (
    <Stack gap={16}>
      <H2>Full process map</H2>
      <Text tone="secondary" size="small">
        Updated 5 Nov 2026 — includes Play now ready-session and Bring KO
        forward. Read top → bottom.
      </Text>

      <Card>
        <CardHeader>Lifecycle flowchart</CardHeader>
        <CardBody>
          <FlowChart />
        </CardBody>
      </Card>

      <H3>0. Entry gates</H3>
      <Table
        headers={["Gate", "If true", "Next"]}
        rows={[
          [
            "Manual black-box",
            "Both match system OFF",
            "Match Day only → month-lock mutual forfeit if unplayed",
          ],
          [
            "Opponent vacant",
            "No arrange loop",
            "Walkover 3–0 at month lock",
          ],
          [
            "New-owner arrange grace",
            "Assigned mid play-month",
            "No propose until next GPSL month",
          ],
          [
            "Catch-up / holiday / attempt 3",
            "Extended or current-month window",
            "Same spine with banner rules",
          ],
        ]}
      />

      <H3>1. Arrange</H3>
      <Table
        headers={["State", "Owner actions", "Next"]}
        rows={[
          [
            "Unscheduled",
            "Home: propose mutual · compromise · poke",
            "Negotiating",
          ],
          [
            "Negotiating",
            "Accept / Counter · Discord lock tab",
            "Accept or Discord both-confirm → Agreed",
          ],
        ]}
      />

      <H3>2. Agreed · kick-off still in the future</H3>
      <Callout tone="info" title="Two different buttons">
        Play now = bilateral ready + 20-min check-in (session overlay). Bring KO
        forward = old earlier-KO request (opponent confirms, UK 10-min).
      </Callout>
      <Table
        headers={["Action", "Rules", "Outcome"]}
        rows={[
          [
            "Play now",
            "Both press; 20 min from first; check-in after own press; no allowance",
            "Both ready → KO forfeit suspended until result / reset / admin clear",
          ],
          [
            "Bring KO forward",
            "Earlier UK 10-min; opponent confirms (24h); no allowance",
            "New agreed KO → normal ±10 check-in",
          ],
          [
            "Change kick-off (mutual)",
            "One free mutual 30-min new-time per fixture",
            "Pending → confirm → new KO",
          ],
          [
            "Voluntary drop",
            "≥24h · 1/month",
            "→ Unscheduled · same attempt",
          ],
          [
            "Emergency drop",
            "&lt;24h · 2/season",
            "→ Unscheduled · attempt 1→2 / 2→3 / 3 stays open play",
          ],
          ["Wait for KO", "Save Match Day squad", "→ Normal check-in ±10"],
        ]}
      />

      <H3>3. Check-in → result</H3>
      <Table
        headers={["Path", "Actions", "Next"]}
        rows={[
          [
            "Normal KO",
            "Check in KO−10→+10 · both in → Match Day",
            "Submit → confirm + stats → played",
          ],
          [
            "Play now session",
            "Both press · check in within countdown",
            "Both in → Match Day · or miss dual path",
          ],
          [
            "After miss (normal or Play now)",
            "Enter result and/or reset",
            "Pending blocks reset until confirm/reject",
          ],
        ]}
      />
    </Stack>
  );
}

function PlayNowTab() {
  return (
    <Stack gap={16}>
      <H2>Play now vs Bring KO forward</H2>
      <Grid columns={3} gap={12}>
        <Stat value="20 min" label="Play now window" />
        <Stat value="Both press" label="Then check-in" />
        <Stat value="Suspended" label="KO forfeit after both ready" />
      </Grid>

      <H3>Play now (ready session)</H3>
      <Table
        headers={["Step", "Detail"]}
        rows={[
          [
            "1. First press",
            "Starts shared 20-min countdown on Schedule (live timer)",
          ],
          [
            "2. Second press",
            "Both ready → ko_forfeit_suspended; original KO check-in fines paused",
          ],
          [
            "3. Check-in",
            "Only after that owner pressed; only while countdown open",
          ],
          [
            "4a. Both check in",
            "Enter result on Match Day → opponent confirms + stats → played (session cleared)",
          ],
          [
            "4b. Window ends incomplete",
            "Fine ladder + dual CTA (enter result / reset Play now)",
          ],
          [
            "One press only expires",
            "No fine; session expired; agreed KO unchanged; check-ins cleared",
          ],
          [
            "Reset / admin clear",
            "As if Play now never pressed; fines already applied stay; KO stands",
          ],
        ]}
      />

      <H3>Bring KO forward (former Play now)</H3>
      <Table
        headers={["", "Play now", "Bring KO forward"]}
        rows={[
          ["UI", "Play now button", "Request Bring KO forward"],
          ["Model", "Session overlay on agreed KO", "Changes agreed KO earlier"],
          ["Confirm", "Both press Play now", "Opponent confirms within 24h"],
          ["Slots", "N/A — play immediately", "UK 10-min earlier than agreed"],
          ["Check-in", "During 20-min session", "Normal ±10 at new KO"],
          ["Allowance", "None", "None"],
        ]}
      />

      <Callout tone="warning" title="Double-fine trap closed">
        After both pressed Play now, the original agreed KO cannot fire
        check-in forfeits until the match is confirmed played, Play now is
        reset, or admin clears the session.
      </Callout>
    </Stack>
  );
}

function AttemptsTab() {
  return (
    <Stack gap={16}>
      <H2>Play attempts</H2>
      <Table
        headers={["Attempt", "Window", "Extras", "Still unplayed at deadline"]}
        rows={[
          [
            "1",
            "Play month + grace (league +2 / cup +1 / May cup +0)",
            "Play now + Bring KO forward after agree",
            "Window awards; no-show fines already instant at miss",
          ],
          [
            "2",
            "Same after new KO / reset",
            "Same toolkit",
            "Ladder escalates on next miss",
          ],
          [
            "3+",
            "Open play through month + 2",
            "Rearrange freely; Play now OK",
            "Fewer no-shows; activity/effort if tied; true tie → 0–0",
          ],
        ]}
      />
    </Stack>
  );
}

function OptionsTab() {
  return (
    <Stack gap={16}>
      <H2>Owner options by stage</H2>
      <Table
        headers={["Stage", "Who", "Buttons / actions"]}
        rows={[
          ["Unscheduled", "Home", "Propose mutual · compromise · poke"],
          ["Negotiating", "Non-proposer", "Accept · Counter · Inbox"],
          ["Negotiating", "Either", "Discord: Lock this kick-off"],
          [
            "Agreed · future",
            "Either",
            "Play now · Bring KO forward · Change KO · Drops",
          ],
          [
            "Play now active",
            "Either",
            "Press Play now · Check in · Cancel · countdown",
          ],
          [
            "Play now miss",
            "See miss rules",
            "Enter result · Reset Play now (keep agreed KO)",
          ],
          ["Normal check-in open", "Either", "Check in now"],
          ["Both checked in", "Either", "Enter result (Match Day)"],
          [
            "After normal miss",
            "See miss tab",
            "Enter result · Pick new time",
          ],
          [
            "Result pending",
            "Opponent",
            "Confirm + stats / Reject — no reschedule",
          ],
        ]}
      />
    </Stack>
  );
}

function DeadlinesTab() {
  return (
    <Stack gap={16}>
      <H2>Deadlines</H2>
      <Grid columns={4} gap={12}>
        <Stat value="Thu 19:00 UK" label="Month lock" />
        <Stat value="KO ±10 min" label="Normal check-in" />
        <Stat value="20 min" label="Play now window" />
        <Stat value="24h" label="Bring-forward expiry" />
      </Grid>
      <Table
        headers={["Clock", "Value"]}
        rows={[
          ["GPSL month", "Thu 19:00 UK → next Thu 19:00 UK"],
          ["Propose-by", "Play-month unlock"],
          ["Late arrange band", "Unlock − 48h"],
          ["Response · counter / catch-up", "+24h"],
          ["Response · first propose late/after open", "+48h"],
          ["Normal check-in", "KO ±10 min"],
          ["Play block (both in)", "KO + 30 min"],
          ["Play now session", "20 min from first press"],
          ["Bring KO forward pending", "Expires 24h"],
          ["Voluntary drop", "≥24h · 1/month · unscheduled same attempt"],
          ["Emergency drop", "<24h · 2/season · unscheduled · escalate 1→2→3"],
          ["Grace", "League +2 · Cup +1 · May cup +0"],
          ["Attempt 3 open play", "Fixture month + 2"],
        ]}
      />
    </Stack>
  );
}

function PenaltiesTab() {
  return (
    <Stack gap={16}>
      <H2>Penalties</H2>
      <Table
        headers={["Trigger", "Penalty", "When"]}
        rows={[
          ["No home proposal", "₿2.5m", "Month lock"],
          ["Late first propose (48h)", "₿1m", "Month lock"],
          ["Reply overdue 1st", "Warning", "Month lock"],
          ["Reply still overdue", "₿1m", "Month lock"],
          ["1st check-in miss", "₿500k + strike", "Instant"],
          ["2nd", "₿1m + strike", "Instant"],
          ["3rd one-sided", "₿1.5m + strike + 0–3", "Instant"],
          [
            "Play now miss (both/onesided)",
            "Same ladder (event key = session start)",
            "Instant at window end",
          ],
          ["Both miss (normal KO)", "Each ladder · KO kept", "Instant"],
          ["Every 3rd season strike", "₿2.5m", "On strike"],
          ["Deferred GPSL month-lock 3–0", "Disabled", "—"],
          ["Emergency with 0 left", "3–0 + ₿3m", "On drop"],
          ["Black-box unplayed", "₿2.5m each + mutual forfeit", "Month lock"],
        ]}
      />
    </Stack>
  );
}

function MissTab() {
  return (
    <Stack gap={16}>
      <H2>After check-in miss</H2>
      <Grid columns={2} gap={12}>
        <Card>
          <CardHeader trailing={<Pill>Normal KO</Pill>}>
            Agreed kick-off miss
          </CardHeader>
          <CardBody>
            <Stack gap={8}>
              <Text size="small">
                Onesided: checked-in enters result; either may pick new time.
                Both miss: either enters or resets. KO kept. Fine ladder.
              </Text>
            </Stack>
          </CardBody>
        </Card>
        <Card>
          <CardHeader trailing={<Pill>Play now</Pill>}>
            Session window miss
          </CardHeader>
          <CardBody>
            <Stack gap={8}>
              <Text size="small">
                Same dual CTAs. Reset clears Play now only (agreed KO stands).
                KO forfeit stays suspended until result, reset, or admin clear.
              </Text>
            </Stack>
          </CardBody>
        </Card>
      </Grid>
      <Table
        headers={["Choice", "Effect"]}
        rows={[
          [
            "Match was played — enter result",
            "Match Day submit for allowed club(s); opponent confirms + stats",
          ],
          [
            "Didn't play — pick new time",
            "Normal miss: catch-up/replay reset → unscheduled",
          ],
          [
            "Reset Play now",
            "Session cleared; agreed KO remains; fines already applied stay",
          ],
          [
            "Result pending",
            "Confirm/reject only — reset blocked",
          ],
        ]}
      />
    </Stack>
  );
}

export default function MatchmakingSystemReview() {
  const [tab, setTab] = useState<TabId>("flow");

  return (
    <Stack gap={20} style={{ maxWidth: 1040, margin: "0 auto", padding: 20 }}>
      <Stack gap={8}>
        <H1>Match-making system review</H1>
        <Text tone="secondary" size="small">
          Live GPSL rules — 5 Nov 2026. Play now ready-session (20 min) + Bring
          KO forward rename + check-in miss dual path.
        </Text>
      </Stack>

      <Grid columns={4} gap={12}>
        <Stat value="20 min" label="Play now window" />
        <Stat value="Bring KO forward" label="Earlier KO rename" />
        <Stat value="Suspended" label="KO forfeit if both ready" />
        <Stat value="Enter or reset" label="After miss" />
      </Grid>

      <TabBar active={tab} onChange={setTab} />
      <Divider />

      {tab === "flow" && <FlowTab />}
      {tab === "playnow" && <PlayNowTab />}
      {tab === "attempts" && <AttemptsTab />}
      {tab === "options" && <OptionsTab />}
      {tab === "deadlines" && <DeadlinesTab />}
      {tab === "penalties" && <PenaltiesTab />}
      {tab === "miss" && <MissTab />}
    </Stack>
  );
}
