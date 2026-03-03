# Container & Package Hierarchy — Power BI Report Implementation Guide

> **Query files:**
>   `queries/ContainersHierarchy_API.pq` — hierarchy (19 output columns)
>   `queries/WeeklyContainerActivity.pq` — weekly activity (20 output columns)
> **DAX measures:** `report/dax_measures.dax`
> **Theme:** `report/ContainerHierarchy.json`

---

## Prerequisites

1. Open your existing `.pbix` file that already contains the **Packages**, **Containers**, and **ContainerTrackingUpdates** queries (Synapse)
2. Confirm those three queries are loading without errors

---

## Step 0 — Load the Query

1. **Home → Transform Data** → opens Power Query Editor
2. **New Source → Blank Query** → opens a new query
3. Open **Advanced Editor**, delete everything, paste the entire contents of `queries/ContainersHierarchy_API.pq`
4. Click **Done** → rename the query to `ContainersHierarchy_API`
5. Click **Close & Apply**
6. Wait for refresh (the API pages will load — ~3 pages of 1000 containers each)

### Verify the Query Loaded Correctly

- The table should have **19 columns**:
  `EffectiveDisplayParentId`, `EffectiveDisplayParentName`, `ParentContainerId`, `ParentContainerName`, `AreaRowName`, `RackName`, `ShelfName`, `ChildContainerId`, `ChildContainerName`, `ChildContainerType`, `PackageName`, `RowKind`, `RelationshipStatus`, `DisplayStatus`, `DisplayState`, `DurationDays`, `ParentContainerQrCode`, `ChildContainerQrCode`, `PackageQrCode`
- `EffectiveDisplayParentName` should show only three values: **180 Campanelli**, **6 Ericsson St**, or **Job Site** — **never** individual project codes or "180 Campanelli IR 6 Ericsson"
- Project containers (e.g. 270005SHW, 180035PGG) appear under the **warehouse** they are physically at (based on their `location` field), and move to **Job Site** only when their tracking status is "Shipped to Jobsite" or "Received on Jobsite"
- `DisplayStatus` should include **"Not Physically Used Yet"** for empty containers with no tracking status
- `DurationDays` should be populated for most rows (numeric)

---

## Step 0b — Load the Weekly Activity Query

1. In Power Query Editor, **New Source → Blank Query**
2. Open **Advanced Editor**, paste the entire contents of `queries/WeeklyContainerActivity.pq`
3. Click **Done** → rename the query to `WeeklyContainerActivity`
4. Click **Close & Apply**
5. Wait for refresh — the query fetches the last 7 days of activity from the API (~2-3 pages)

> **Note:** This query references `ContainersHierarchy_API`, so that query must load first.

### Verify the Activity Query

- The table should have **20 columns**:
  `ActivityDateTime`, `ActivityDate`, `ActivityDay`, `ActivityUser`, `ActionName`, `ActivityType`, `Route`, `ItemName`, `ItemType`, `ProjectName`, `ProjectNumber`, `TrackingStatusName`, `TrackingStatusColor`, `DivisionName`, `ParentContainerName`, `ChildContainerName`, `EffectiveDisplayParentName`, `ParentContainerQrCode`, `ChildContainerQrCode`, `PackageQrCode`
- `ActivityType` values: "Item Added to Container", "Container Status Changed", "Package Status Changed", "Package Archived / Unarchived"
- `ActivityDate` should show dates from the past 7 days only
- Container context columns (`ParentContainerName`, `ChildContainerName`, `EffectiveDisplayParentName`) are populated via join to the hierarchy query

---

## Step 1 — Apply the Theme

1. **View → Themes → Browse for themes**
2. Select `report/ContainerHierarchy.json`
3. Click **Apply**

Facility color assignments for charts:
| Facility | Color | Hex |
|---|---|---|
| 180 Campanelli | Blue | `#0078D4` |
| 6 Ericsson St | Teal | `#00B7C3` |
| Job Site | Green | `#107C10` |

---

## Step 2 — Create DAX Measures

Open `report/dax_measures.dax` and create each measure one at a time:

1. Select `ContainersHierarchy_API` table in the Fields pane
2. **Modeling → New Measure**
3. Paste the measure formula, press Enter
4. Repeat for all measures

### Measures to Create (in order)

| # | Measure Name | Purpose |
|---|---|---|
| 1 | `Total Active Packages` | KPI card — count of real packages |
| 2 | `Empty Containers` | KPI card — ChildNoPackage row count |
| 3 | `Not Physically Used` | KPI card — containers with no status |
| 4 | `Avg Duration Days` | KPI card — average aging |
| 5 | `Containers at Job Site` | KPI card — job site count |
| 6 | `Package Count` | Chart values — packages only |
| 7 | `Row Count` | Chart values — all rows |
| 8 | `Unique Containers` | Page 2 card |
| 9 | `Unique Parents` | Page 2 card |
| 10 | `Max Duration Days` | Page 3 stats |
| 11 | `Min Duration Days` | Page 3 stats |
| 12 | `Median Duration Days` | Page 3 stats |
| 13 | `Containers Over 90 Days` | Page 3 alert |
| 14 | `Containers Over 60 Days` | Page 3 alert |
| 15 | `Duration Bucket` | Aging categorization (calculated column — see Step 3) |
| 16 | `Campanelli Package Count` | Facility card |
| 17 | `Ericsson Package Count` | Facility card |
| 18 | `Job Site Package Count` | Facility card |
| 19 | `Duration Color` | Conditional formatting field |
| 20 | `Status Color` | Conditional formatting field |
| 21 | `Total Activities This Week` | Page 4 KPI — total activity count |
| 22 | `Status Changes This Week` | Page 4 KPI — status change count |
| 23 | `Items Added to Containers This Week` | Page 4 KPI — items added |
| 24 | `Unique Users This Week` | Page 4 KPI — distinct users |
| 25 | `Unique Containers Touched This Week` | Page 4 KPI — containers with activity |
| 26 | `Activity Count` | Page 4 chart values |

After creating all measures, select them all → **Properties → Display Folder** = `Measures`

---

## Step 3 — Create Duration Bucket Calculated Columns

This gives every row an aging category for slicers and legends. You need **two** columns — the text label and a numeric sort key.

### 3a. Duration Bucket (text label)

1. Select the `ContainersHierarchy_API` table
2. **Modeling → New Column**
3. Paste:

```dax
Duration Bucket =
SWITCH(
    TRUE(),
    'ContainersHierarchy_API'[DurationDays] <= 30, "0-30 days",
    'ContainersHierarchy_API'[DurationDays] <= 60, "31-60 days",
    'ContainersHierarchy_API'[DurationDays] <= 90, "61-90 days",
    'ContainersHierarchy_API'[DurationDays] > 90,  "90+ days",
    "Unknown"
)
```

### 3b. Duration Bucket Sort (numeric sort key)

1. **Modeling → New Column** again
2. Paste:

```dax
Duration Bucket Sort =
SWITCH(
    TRUE(),
    'ContainersHierarchy_API'[DurationDays] <= 30, 1,
    'ContainersHierarchy_API'[DurationDays] <= 60, 2,
    'ContainersHierarchy_API'[DurationDays] <= 90, 3,
    'ContainersHierarchy_API'[DurationDays] > 90,  4,
    5
)
```

### 3c. Set sort order

1. In the Fields pane, click **Duration Bucket** to select it
2. **Column tools → Sort by Column → Duration Bucket Sort**
3. Optionally hide `Duration Bucket Sort`: right-click → **Hide in report view**

---

## Step 4 — Page 1: Executive Summary

### 4a. Create the page
- Right-click Page 1 tab → **Rename** → `Summary`
- Page size: View → Page size → 16:9

### 4b. KPI Card Row (top, left to right)

Create 5 **Card** visuals across the top ~15% of the page.

> **Note:** In newer Power BI Desktop, the Card visual shows **Value**, **Trend axis**, and **Target** wells. Drag the measure into the **Value** well. Leave Trend axis and Target empty.

For each card:
1. Insert a **Card** visual from the Visualizations pane
2. Drag the measure into the **Value** well
3. Format the callout value and category label in the Format pane

| Card | Drag to Value | Format |
|---|---|---|
| 1 | `[Total Active Packages]` | Callout: 28pt, category label "Active Packages" |
| 2 | `[Empty Containers]` | Callout: 28pt, category label "Empty Containers" |
| 3 | `[Not Physically Used]` | Callout: 28pt, **orange text** `#FF8C00`, category label "Not Physically Used" |
| 4 | `[Avg Duration Days]` | Callout: 28pt, 1 decimal, category label "Avg Duration (Days)" |
| 5 | `[Containers at Job Site]` | Callout: 28pt, category label "At Job Site" |

### 4c. Clustered Bar Chart (middle-left, ~50% width)

- **Axis:** `EffectiveDisplayParentName`
- **Values:** `[Package Count]`
- Title: "Packages by Facility"
- Format → Data colors:
  - 180 Campanelli → `#0078D4`
  - 6 Ericsson St → `#00B7C3`
  - Job Site → `#107C10`
  - All others → `#8764B8`

### 4d. Donut Chart (middle-right, ~25% width)

- **Legend:** `RowKind`
- **Values:** `[Row Count]`
- Title: "Row Distribution"
- Detail labels: Show category + percentage

### 4e. Stacked Bar Chart (middle-right, below donut, ~25% width)

- **Axis:** `EffectiveDisplayParentName`
- **Values:** `[Avg Duration Days]`
- **Legend:** `RowKind`
- Title: "Avg Duration by Facility"

### 4f. Table — Top 20 Longest Duration (bottom, full width)

- Columns: `ChildContainerName`, `ChildContainerType`, `EffectiveDisplayParentName`, `DisplayStatus`, `DisplayState`, `DurationDays`
- **Top N filter:** `DurationDays` → Top 20 → By value: `DurationDays`
- Sort: `DurationDays` descending
- Conditional formatting on `DurationDays`:
  - Right-click column header → Conditional formatting → Background color
  - Format by: Rules
  - \>90 → `#D13438` (red), 31-90 → `#FFB900` (yellow), 0-30 → `#107C10` (green)
- Conditional formatting on `DisplayStatus`:
  - Format by: Rules
  - "Not Physically Used Yet" → Background `#FF8C00` (orange), font white

### 4g. Slicers (top strip, above cards)

| Slicer | Field | Style |
|---|---|---|
| 1 | `EffectiveDisplayParentName` | Dropdown |
| 2 | `RowKind` | Dropdown |
| 3 | `DisplayStatus` | Dropdown |

---

## Step 5 — Page 2: Hierarchy Detail

### 5a. Create the page
- Click **+** to add a new page → rename to `Hierarchy Detail`

### 5b. Matrix Visual (main, ~75% of page)

- **Rows (hierarchy, in order):**
  1. `EffectiveDisplayParentName`
  2. `ParentContainerName`
  3. `AreaRowName`
  4. `RackName`
  5. `ShelfName`
  6. `ChildContainerName`
  7. `PackageName`
- **Values:**
  1. `DisplayStatus`
  2. `DisplayState`
  3. `DurationDays`
  4. `ChildContainerType`
  5. `RelationshipStatus`
- Format:
  - Stepped layout: **On**
  - Row subtotals: **Off** (Format → Subtotals → Row subtotals → Off)
  - Column subtotals: **Off**
  - Alternating row colors: light gray `#F5F5F5`
- Conditional formatting on `DisplayStatus`:
  - "Not Physically Used Yet" → Background orange `#FF8C00`, font white
  - "Shipped to Jobsite" / "Received on Jobsite" → Background green `#107C10`, font white
- Conditional formatting on `DurationDays`:
  - Data bars: Min green `#107C10`, Max red `#D13438`

### 5c. Cards (top-right corner)

Create 3 separate **Card** visuals, each with one measure in the **Value** well:
- Card 1: `[Package Count]`
- Card 2: `[Empty Containers]`
- Card 3: `[Avg Duration Days]`
- These respond to the current slicer selection

### 5d. Slicers (top strip)

| Slicer | Field | Style | Notes |
|---|---|---|---|
| 1 | `EffectiveDisplayParentName` | Dropdown | Sync with Page 1 |
| 2 | `ChildContainerType` | Dropdown | Cart, Pallet, Basket, etc. |
| 3 | `DisplayStatus` | Dropdown | Includes "Not Physically Used Yet" |
| 4 | `DurationDays` | Numeric range | Between mode |

### 5e. Sync Slicers

- **View → Sync slicers**
- Select the `EffectiveDisplayParentName` slicer
- Check sync + visible for both Page 1 and Page 2

---

## Step 6 — Page 3: Status & Duration Breakdown

### 6a. Create the page
- Click **+** → rename to `Status & Duration`

### 6b. Stacked Column Chart (top-left, ~50% width)

- **Axis:** `DisplayStatus`
- **Values:** `[Row Count]`
- **Legend:** `EffectiveDisplayParentName`
- Title: "Container Count by Status"
- Note: The "Not Physically Used Yet" bar will be prominent

### 6c. Scatter Plot (top-right, ~50% width)

- **X Axis:** `DurationDays`
- **Y Axis:** `[Row Count]`
- **Details:** `ChildContainerName`
- **Legend:** `DisplayStatus`
- Title: "Duration vs. Count by Status"
- Point size: small (5-8)

### 6d. Table — "Not Physically Used Yet" (bottom-left, ~50% width)

- Columns: `ChildContainerName`, `ChildContainerType`, `EffectiveDisplayParentName`, `ParentContainerName`, `DisplayState`, `DurationDays`
- **Visual-level filter:** `DisplayStatus` = "Not Physically Used Yet"
- Sort: `DurationDays` descending
- Title: "Not Physically Used Yet — Containers"
- Conditional formatting on `DurationDays`:
  - Rules: >60 → red `#D13438`, 31-60 → yellow `#FFB900`, 0-30 → green `#107C10`

### 6e. Table — Parent Containers by Last Child Added (bottom-right, ~50% width)

- Columns: `ParentContainerName`, `EffectiveDisplayParentName`, `DisplayState`, `DurationDays`
- **Visual-level filter:** `RowKind` = "ParentEmpty"
- Sort: `DurationDays` descending
- Title: "Parent Containers — Time Since Last Child"
- Conditional formatting on `DurationDays`: same rules as 6d

### 6f. Slicers (top strip)

| Slicer | Field | Style |
|---|---|---|
| 1 | `EffectiveDisplayParentName` | Dropdown (synced) |
| 2 | `RowKind` | Dropdown |
| 3 | `DurationDays` | Numeric range (Between) |

### 6g. Sync Slicers

- Sync `EffectiveDisplayParentName` across all 3 pages

---

## Step 7 — Page 4: Weekly Activity Report

This page powers the **Friday email subscription** — it shows all container and package activity from the past 7 days.

### 7a. Create the page
- Click **+** → rename to `Weekly Activity`

### 7b. KPI Card Row (top, 5 cards)

| Card | Drag to Value | Format |
|---|---|---|
| 1 | `[Total Activities This Week]` | Callout: 28pt, category label "Total Activities" |
| 2 | `[Status Changes This Week]` | Callout: 28pt, category label "Status Changes" |
| 3 | `[Items Added to Containers This Week]` | Callout: 28pt, category label "Items Added to Containers" |
| 4 | `[Unique Users This Week]` | Callout: 28pt, category label "Active Users" |
| 5 | `[Unique Containers Touched This Week]` | Callout: 28pt, category label "Containers Touched" |

### 7c. Clustered Bar Chart (left, ~50% width)

- **Axis:** `ActivityDay`
- **Values:** `[Activity Count]`
- **Legend:** `ActivityType`
- Title: "Activity by Day"
- Sort by `ActivityDate` ascending (click the chart → sort icon → `ActivityDate`)

### 7d. Donut Chart (right, ~25% width)

- **Legend:** `ActivityType`
- **Values:** `[Activity Count]`
- Title: "Activity Breakdown"
- Detail labels: Show category + percentage

### 7e. Stacked Bar Chart (right, below donut, ~25% width)

- **Axis:** `EffectiveDisplayParentName`
- **Values:** `[Activity Count]`
- **Legend:** `ActivityType`
- Title: "Activity by Facility"
- Data colors: Campanelli `#0078D4`, Ericsson `#00B7C3`, Job Site `#107C10`

### 7f. Activity Detail Table (bottom, full width)

This table is the core of the email — it shows every individual activity event.

- **Columns (in order):**
  `ActivityDate`, `ActivityUser`, `ActivityType`, `ItemName`, `ProjectName`,
  `TrackingStatusName`, `ParentContainerName`, `ChildContainerName`,
  `EffectiveDisplayParentName`, `ChildContainerQrCode`, `PackageQrCode`
- Sort: `ActivityDateTime` descending (newest first)
- Conditional formatting on `ActivityType`:
  - "Item Added to Container" → Background `#E6F2E6` (light green)
  - "Container Status Changed" → Background `#E6F0FA` (light blue)
  - "Package Status Changed" → Background `#FFF4E6` (light orange)
- Conditional formatting on `TrackingStatusName`:
  - "Shipped to Jobsite" / "Received on Jobsite" → Background `#107C10`, font white
  - "Fabrication Complete" → Background `#00B7C3`, font white

### 7g. Slicers (top strip)

| Slicer | Field | Style |
|---|---|---|
| 1 | `EffectiveDisplayParentName` | Dropdown (synced) |
| 2 | `ActivityType` | Dropdown |
| 3 | `ActivityUser` | Dropdown |
| 4 | `ProjectName` | Dropdown |
| 5 | `ActivityDate` | Date range (Between) |

### 7h. Sync Slicers

- Sync `EffectiveDisplayParentName` across all 4 pages

---

## Step 8 — Friday Email Subscription

To automatically email the Weekly Activity page every Friday:

### Option A: Power BI Service Subscription (simplest)

1. **Publish** the report to Power BI Service:
   - In Power BI Desktop: **Home → Publish → select your workspace**
2. Open the report in **app.powerbi.com**
3. Navigate to the **Weekly Activity** page
4. Click **Subscribe to report** (envelope icon in the toolbar), or **File → Subscribe**
5. Configure the subscription:
   - **Subscriber:** Add yourself and the other recipients' email addresses
   - **Subject:** `Weekly Container Activity Report`
   - **Page:** `Weekly Activity`
   - **Frequency:** Weekly
   - **Day:** Friday
   - **Time:** Pick a time (e.g. 5:00 PM)
   - **Start date / End date:** Set as needed
   - **Include preview image:** Yes (embeds a snapshot of the page in the email)
6. Click **Save and close**

> **Prerequisite:** The dataset must have a **scheduled refresh** so the data is current when the subscription fires. Set this under Dataset settings → Scheduled refresh → add a Friday refresh at least 1 hour before the subscription time.

### Option B: Power Automate (more flexible)

Use this if you want to attach an exported PDF/CSV, customize the email body, or send to external recipients.

1. Go to **flow.microsoft.com** → **Create → Scheduled cloud flow**
2. **Trigger:** Recurrence — Every 1 Week, on Friday, at e.g. 5:00 PM
3. **Action 1:** Power BI → **Export to file for Power BI Report**
   - Workspace: Your workspace
   - Report: Your published report
   - Pages: `Weekly Activity` (select by page name)
   - Export format: PDF (or PNG, PPTX)
4. **Action 2:** **Send an email (V2)** (Office 365 Outlook connector)
   - To: Your email + other recipients (semicolon-separated)
   - Subject: `Weekly Container Activity Report — @{formatDateTime(utcNow(), 'yyyy-MM-dd')}`
   - Body: Brief summary text + "See attached PDF for full details"
   - Attachments:
     - Name: `WeeklyActivity_@{formatDateTime(utcNow(), 'yyyy-MM-dd')}.pdf`
     - Content: Output from the Export action
5. **Save** the flow
6. Test with **Test → Manually** to confirm the email arrives

### Option C: Power Automate with Data Rows (richest)

If you want the actual data rows in the email body (not just a page screenshot):

1. **Trigger:** Recurrence — Weekly, Friday
2. **Action 1:** Power BI → **Run a query against a dataset**
   - Use this DAX query:
   ```dax
   EVALUATE
   SELECTCOLUMNS(
       'WeeklyContainerActivity',
       "Date", [ActivityDate],
       "User", [ActivityUser],
       "Activity", [ActivityType],
       "Item", [ItemName],
       "Project", [ProjectName],
       "Status", [TrackingStatusName],
       "Container", [ChildContainerName],
       "Facility", [EffectiveDisplayParentName]
   )
   ```
3. **Action 2:** Create HTML table from the query results
4. **Action 3:** Send email with the HTML table in the body

---

## Step 9 — Final Checks

### Verification Checklist

- [ ] `EffectiveDisplayParentName` slicer shows exactly three values: **180 Campanelli**, **6 Ericsson St**, **Job Site**
- [ ] **Never** shows individual project codes (e.g. 270005SHW, 180035PGG) or "180 Campanelli IR 6 Ericsson"
- [ ] "Not Physically Used Yet" appears in `DisplayStatus` for empty/no-status containers
- [ ] `DurationDays` is populated — check a few rows in the matrix
- [ ] `DisplayState` shows labels like "X days since creation", "X days in current status", "X days since last child added"
- [ ] Spot-check **PH-051**: should show DisplayStatus = "Not Physically Used Yet", DurationDays = numeric value
- [ ] Conditional formatting colors render: green (0-30), yellow (31-90), red (90+)
- [ ] Orange highlight on "Not Physically Used Yet" rows
- [ ] Slicer sync works across all 4 pages
- [ ] Duration range slicer on Page 2 filters the matrix correctly
- [ ] Card KPIs update when slicers are changed
- [ ] All 4 pages render without errors
- [ ] `WeeklyContainerActivity` query loads with data from the last 7 days
- [ ] Activity table shows `ActivityType`, `ItemName`, container context
- [ ] Email subscription delivers on Friday (test with manual trigger first)

### Performance Notes

- The query uses `Table.Buffer()` on frequently-joined tables to reduce re-evaluation
- First refresh will be slow (~30-60s) due to API paging
- Subsequent refreshes benefit from Power BI's query caching
- If the matrix is slow with all hierarchy levels expanded, consider collapsing by default (Format → Row headers → Expand/collapse → Default to collapsed)

---

## Column Reference

| Column | Type | Description |
|---|---|---|
| `EffectiveDisplayParentId` | text (nullable) | Synthetic ID: SYN-180CAMP, SYN-6ERIC, SYN-JOBSITE, or API id |
| `EffectiveDisplayParentName` | text | Facility: "180 Campanelli", "6 Ericsson St", or "Job Site" (only 3 values) |
| `ParentContainerId` | text (nullable) | API container id of the parent |
| `ParentContainerName` | text (nullable) | Display name of the parent container |
| `AreaRowName` | text (nullable) | ROW A, ROW B, etc. |
| `RackName` | text (nullable) | Rack name within the area row |
| `ShelfName` | text (nullable) | Shelf name within the rack |
| `ChildContainerId` | text (nullable) | API container id of the child |
| `ChildContainerName` | text | Child container name, "(Directly on Parent)", or "(No Container)" |
| `ChildContainerType` | text (nullable) | Cart, Pallet, Basket, Box, Shipping |
| `PackageName` | text | Package name or "(No Package)" |
| `RowKind` | text | ChildPackage, ParentDirectPackage, UncontainedPackage, ChildNoPackage, ParentEmpty |
| `RelationshipStatus` | text | How the row was resolved |
| `DisplayStatus` | text (nullable) | Tracking status name or "Not Physically Used Yet" |
| `DisplayState` | text (nullable) | "X days since creation", "X days in current status", "X days since last child added" |
| `DurationDays` | number (nullable) | Numeric day count for sorting/filtering |
| `ParentContainerQrCode` | text (nullable) | QR code URL for the parent container |
| `ChildContainerQrCode` | text (nullable) | QR code URL for the child container |
| `PackageQrCode` | text (nullable) | QR code URL for the package |

### WeeklyContainerActivity Columns

| Column | Type | Description |
|---|---|---|
| `ActivityDateTime` | datetime | Timestamp of the activity event |
| `ActivityDate` | date | Date only (for grouping/slicers) |
| `ActivityDay` | text | Day of week name (Monday, Tuesday, etc.) |
| `ActivityUser` | text (nullable) | Who performed the action |
| `ActionName` | text | Raw action name from API |
| `ActivityType` | text | Friendly label: "Item Added to Container", "Package Status Changed", etc. |
| `Route` | text | API route that generated the event |
| `ItemName` | text (nullable) | Name of the package or assembly affected |
| `ItemType` | text (nullable) | "Package" or "Assembly" |
| `ProjectName` | text (nullable) | Project display name |
| `ProjectNumber` | text (nullable) | Project code (e.g. 320001TUR) |
| `TrackingStatusName` | text (nullable) | New tracking status after the action |
| `TrackingStatusColor` | text (nullable) | Hex color of the tracking status |
| `DivisionName` | text (nullable) | Workstation / division that performed the action |
| `ParentContainerName` | text (nullable) | Parent container (joined from hierarchy) |
| `ChildContainerName` | text (nullable) | Child container (joined from hierarchy) |
| `EffectiveDisplayParentName` | text (nullable) | Facility: 180 Campanelli / 6 Ericsson St / Job Site |
| `ParentContainerQrCode` | text (nullable) | QR code URL for the parent container |
| `ChildContainerQrCode` | text (nullable) | QR code URL for the child container |
| `PackageQrCode` | text (nullable) | QR code URL for the package |
