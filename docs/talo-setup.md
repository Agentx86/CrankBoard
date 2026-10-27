# Setting up Talo

[Talo](https://trytalo.com) is the free online service that stores the scores. You set it up once
per game; it takes about 5 minutes. At the end you will have two things to paste into your game:

- the **internal name** of each leaderboard, for example `highscores`;
- an **access key**, a long text that lets your game talk to Talo.

## 1. Create an account and a game

1. Go to [trytalo.com](https://trytalo.com) and sign up (it's free).
2. Create a **game**. Use your game's name; players don't see it.

After signing up, the dashboard shows a "Please confirm your email address" banner. You can confirm
later: creating the game, the leaderboards and the key works before that.

## 2. Decide which leaderboards you need

A leaderboard is one table of scores. Pick the row that matches your game:

| What you want | Leaderboards to create (Internal name: Refresh entries) |
|---|---|
| One table, best scores of all time | `highscores`: Never |
| This week, this month and all time | `weekly`: Weekly, `monthly`: Monthly, `alltime`: Never |
| One table per difficulty (Easy, Normal, Hard), all time | `easy`: Never, `normal`: Never, `hard`: Never |
| One table per level or mode | one leaderboard per level, e.g. `level-1`, `level-2`, ... |

The names are up to you; they just have to match what you write in your game. Use short names
with lowercase letters, numbers and dashes: they are case-sensitive, so `Weekly` and `weekly` are
two different leaderboards.

## 3. Create each leaderboard

Open **Leaderboards** and click **Create leaderboard**. Fill in the form:

| Field | What to choose |
|---|---|
| **Internal name** | The name from the table above, e.g. `highscores`. You will use it in your code. |
| **Display name** | Any name you like, e.g. "High scores". Only you see it in the dashboard. |
| **Sort mode** | **Descending** if a bigger score is better (points). **Ascending** if a smaller score is better (time, number of moves). |
| **Refresh entries** | **Never** for all-time tables. **Weekly** or **Monthly** (or Daily, Yearly) for tables that start empty again every week or month. |
| **Unique entries only?** | **Yes**. Each player then has one entry, their best score. |
| **Unique by props?** | **No**. With Yes, every different set of extra data (like the level) makes a separate entry, so one player gets several rows. |

**Check both "Unique" fields before you click Create**, whatever they show when the form opens:
the form doesn't always start with the same choices. You need *Unique entries only? = Yes* and
*Unique by props? = No*.

Click **Create**. Repeat for every leaderboard you need.

> With **Refresh entries: Weekly** the table starts empty every Monday. Old scores aren't lost:
> Talo keeps them, they just don't show in the current week.

## 4. Create an access key

1. Open **API keys** and click **Create API key**.
2. Key type: **Game API key**.
3. Tick these permissions (scopes):
   - **Players**: read and write (`read:players`, `write:players`)
   - **Leaderboards**: read and write (`read:leaderboards`, `write:leaderboards`)
   - optional: **Continuity requests**: write (`write:continuityRequests`). When a score is sent later
     because there was no Wi-Fi, it keeps the date of the game instead of the date it was sent.
4. Click **Create** and **copy the key right away**: Talo shows it only once. If you lose it,
   just create a new one.

Give the key only these permissions. The key is stored inside your game, so a curious player could
find it; with these permissions it can only add scores and read leaderboards, nothing else.

## 5. Recommended: use the player's current name

CrankBoard saves the name the player typed in a player property called `name`, and a copy of it with
every score. Open **Game settings** and set **Display name prop key** to `name`. Then:

- a player who changes their name shows up with the new name everywhere. Without it, a leaderboard
  where they haven't sent a score since the change still shows the old name (the copy saved with
  that score);
- the Talo dashboard lists players by that name.

## 6. Paste it into your game

```lua
crankboard.setup({
    accessKey = "the key you copied",
    leaderboard = "highscores",     -- the Internal name
})
```

If your game's code is in git (on GitHub, for example), keep the key in a separate file instead:
see [Keep the access key out of git](../README.md#keep-the-access-key-out-of-git).

With several leaderboards, list them all (the order is the order of the tabs players see):

```lua
crankboard.setup({
    accessKey = "the key you copied",
    leaderboards = {
        { name = "weekly", title = "This week" },
        { name = "monthly", title = "This month" },
        { name = "alltime", title = "All time" },
    },
})
```

## Where do I see the scores?

Open **Leaderboards** in the Talo dashboard and click a leaderboard.

Scores sent from the **Playdate Simulator** are marked as test data ("dev data"), so testing never
fills your real tables with junk. The dashboard hides them until you turn dev data on (look for
"Dev data is currently not enabled" and switch it on). Scores from a real Playdate are always shown.

You can hide or delete any entry from the dashboard, for example an obvious cheat.
