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
        Read top → bottom. Side paths branch off Agreed (future KO) and after
        check-in. Chat has the full Mermaid diagram if this panel is hard to
        read.
      </Text>

      <H3>0. Entry gates</H3>
      <Table
        headers={["Gate", "If true", "Next"]}
        rows={[
          [
            "Manual black-box (both match system OFF)",
            "No propose / check-in / Play now",
            "Match Day only → month-lock mutual forfeit if unplayed",
          ],
          [
            "Opponent vacant / season-absent",
            "No arrange loop",
            "Walkover 3–0 at month lock",
          ],
          [
            "New-owner arrange grace",
            "No propose / Discord until next GPSL month",
            "Normal path after grace",
          ],
          [
            "Catch-up / holiday early / attempt 3 open play",
            "Window / banner rules change",
            "Same spine with extended or current-month window",
          ],
        ]}
      />

      <H3>1. Arrange spine</H3>
      <Table
        headers={["State", "Owner actions", "Next"]}
        rows={[
          [
            "Unscheduled",
            "Home: propose mutual · compromise · poke (if no mutuals)",
            "Negotiating + pending proposal",
          ],
          [
            "Negotiating",
            "Non-proposer: Accept / Counter · Either: Discord lock tab",
            "Accept or Discord both-confirm → Agreed · Counter → stay Negotiating",
          ],
          [
            "Discord lock (pre-agree)",
            "Pick 30-min slot → Lock · opponent Confirm/Decline (24h)",
            "Both confirm → Agreed (does not burn free new-time)",
          ],
        ]}
      />

      <H3>2. Agreed · kick-off still in the future</H3>
      <Callout tone="info" title="Play now lives here">
        Schedule page, Agreed panel — only while agreed KO is still future and
        there is no pending mutual/Discord override. See Play now tab.
      </Callout>
      <Table
        headers={["Action", "Rules", "Outcome"]}
        rows={[
          [
            "Play now",
            "Either; UK 10-min; must be earlier than agreed KO; no weekly mutual required; no allowance",
            "Pending override → both confirm → new earlier KO; check-ins cleared",
          ],
          [
            "Change kick-off (mutual new-time)",
            "One free per fixture after already agreed; mutual 30-min slots only",
            "Pending → confirm → new KO; mutual_override_used = true",
          ],
          [
            "Voluntary drop (≥24h)",
            "1 reschedule / GPSL month; not catch-up",
            "→ Unscheduled",
          ],
          [
            "Emergency drop (<24h)",
            "2 / season; not catch-up",
            "→ Unscheduled (0 left → forfeit path if used)",
          ],
          [
            "Wait for KO",
            "Save Match Day squad",
            "→ Check-in window",
          ],
        ]}
      />

      <H3>3. Check-in → play → result</H3>
      <Table
        headers={["Moment", "Actions", "Next"]}
        rows={[
          [
            "KO−10 → KO+10",
            "Check in now (squad validated)",
            "Both in → play block · Window closes incomplete → miss path",
          ],
          [
            "Both in + KO → KO+30",
            "Enter result on Match Day",
            "Pending submission",
          ],
          [
            "Pending result",
            "Opponent confirm + stats (or reject)",
            "Played · reschedule blocked while pending",
          ],
          [
            "After confirm",
            "Video / Discord match prefers confirmed result",
            "Done",
          ],
        ]}
      />

      <H3>4. After check-in miss (KO kept)</H3>
      <Table
        headers={["Situation", "Enter result", "Pick new time"]}
        rows={[
          [
            "Onesided — you checked in",
            "Yes (you)",
            "Either may reset if allowed",
          ],
          [
            "Onesided — you missed",
            "No (opponent only)",
            "You may still pick new time",
          ],
          [
            "Both missed",
            "Either",
            "Either",
          ],
          [
            "Result already pending",
            "Confirm/reject only",
            "Blocked until resolved",
          ],
        ]}
      />

      <H3>5. Back to arrange</H3>
      <Text size="small">
        Drops and pick-new-time / catch-up reset → Unscheduled → home proposes
        again (attempt ladder may already have bumped). Play now / new-time stay
        on Agreed and do not unschedule.
      </Text>
    </Stack>
  );
}

function PlayNowTab() {
  return (
    <Stack gap={16}>
      <H2>Play now — where and how</H2>
      <Grid columns={3} gap={12}>
        <Stat value="Agreed panel" label="Where in UI" />
        <Stat value="Future KO only" label="When visible" />
        <Stat value="No allowance" label="Cost" />
      </Grid>

      <Callout tone="info" title="Location">
        Fixture Schedule → fixture must already be Agreed with a kick-off still
        in the future. Panel title: “Play now (no allowance used)”. Not on Match
        Day. Hidden if a mutual/Discord confirm is already pending.
      </Callout>

      <H3>Flow</H3>
      <Table
        headers={["Step", "Detail"]}
        rows={[
          [
            "1. Request",
            "Either owner picks earlier UK 10-minute time → Request Play now → fixture_mutual_override_request (kind play_now)",
          ],
          [
            "2. Pending",
            "Requester auto-confirmed; opponent Confirm or Decline (expires 24h)",
          ],
          [
            "3. Applied",
            "Both confirm → agreed_kickoff_at moves earlier; check-ins wiped; then normal check-in at new KO",
          ],
        ]}
      />

      <H3>vs Change kick-off (mutual new-time)</H3>
      <Table
        headers={["", "Play now", "Mutual new-time"]}
        rows={[
          ["Slot", "Any earlier UK 10-min (no weekly mutual)", "Mutual 30-min weekly slots only"],
          ["Must be earlier than agreed?", "Yes", "Can be another mutual slot (both agree)"],
          ["Allowance", "None", "None (but one free use per fixture)"],
          ["Repeatable?", "Yes while KO still future", "Once (mutual_override_used)"],
          ["Pre-agree Discord lock?", "No — need agreed KO first", "Discord tab uses new_time to lock first KO"],
        ]}
      />

      <H3>Blockers</H3>
      <Text size="small">
        Agreed KO already past · play window / attempt-3 deadline closed ·
        holiday-early squad under 24 · double-booked · next 10-min slot would not
        be earlier than agreed · pending override already open · no manager.
      </Text>
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
            "Full toolkit incl. Play now after agree",
            "Window awards; no-show fines already instant at miss",
          ],
          [
            "2",
            "Same after new KO / reset",
            "Same; banner shows attempt 2",
            "Ladder escalates on next miss",
          ],
          [
            "3+",
            "Open play through month + 2",
            "Rearrange freely; Play now OK",
            "Award to fewer no-shows (activity if tied)",
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
          [
            "Unscheduled",
            "Home",
            "Propose mutual · compromise · poke",
          ],
          [
            "Negotiating",
            "Non-proposer",
            "Accept · Counter · Inbox",
          ],
          [
            "Negotiating",
            "Either",
            "Discord: Lock this kick-off → Confirm/Decline",
          ],
          [
            "Agreed · future",
            "Either",
            "Play now · Change KO (1 free) · Drop ≥24h · Emergency <24h",
          ],
          [
            "Agreed · check-in open",
            "Either",
            "Check in now",
          ],
          [
            "Both checked in",
            "Either",
            "Enter result (Match Day)",
          ],
          [
            "After miss",
            "See miss tab",
            "Enter result and/or pick new time",
          ],
          [
            "Result pending",
            "Opponent",
            "Confirm + stats / Reject — no reschedule",
          ],
          [
            "Catch-up / past KO",
            "Either",
            "Pick new time / Reset catch-up",
          ],
          [
            "Black-box / vacant",
            "—",
            "Match Day only / walkover — no arrange",
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
        <Stat value="KO ±10 min" label="Check-in" />
        <Stat value="30 min" label="Play block" />
        <Stat value="24h" label="Override expiry" />
      </Grid>
      <Table
        headers={["Clock", "Value"]}
        rows={[
          ["GPSL month", "Thu 19:00 UK → next Thu 19:00 UK"],
          ["Propose-by", "Play-month unlock"],
          ["Late arrange band", "Unlock − 48h"],
          ["Response · counter / catch-up", "+24h"],
          ["Response · first propose late/after open", "+48h"],
          ["Check-in", "KO ±10 min"],
          ["Play block", "KO + 30 min"],
          ["Play now / mutual pending", "Expires 24h"],
          ["Voluntary drop", "≥24h before KO · 1/month"],
          ["Emergency drop", "<24h · 2/season"],
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
          ["Reply still overdue", "₿2.5m", "Month lock"],
          ["1st check-in miss", "₿500k + strike", "Instant"],
          ["2nd", "₿1m + strike", "Instant"],
          ["3rd one-sided", "₿1.5m + strike + 0–3", "Instant"],
          ["Both miss", "Each ladder (usually ₿500k + strike)", "Instant · KO kept"],
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
          <CardHeader trailing={<Pill>One checked in</Pill>}>
            Onesided
          </CardHeader>
          <CardBody>
            <Text size="small">
              Misser fined. Checked-in may enter result. Either may pick new
              time. Opponent confirms + stats after submit.
            </Text>
          </CardBody>
        </Card>
        <Card>
          <CardHeader trailing={<Pill>Neither in</Pill>}>Both miss</CardHeader>
          <CardBody>
            <Text size="small">
              Both fined. Either enters result or picks new time. KO not
              auto-cleared. Pending result blocks reset.
            </Text>
          </CardBody>
        </Card>
      </Grid>
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
          Full process incl. Play now, Discord lock, drops, poke/compromise,
          miss dual-path. Nov 2026 live rules.
        </Text>
      </Stack>

      <Grid columns={4} gap={12}>
        <Stat value="Agreed · future" label="Play now shows" />
        <Stat value="UK 10-min" label="Play now slots" />
        <Stat value="No allowance" label="Play now cost" />
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
