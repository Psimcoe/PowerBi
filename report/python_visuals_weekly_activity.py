# =====================================================================
#  Python Visual Scripts for Page 4: Weekly Activity
#  ──────────────────────────────────────────────────
#  Each section below is a separate Python visual in Power BI.
#
#  HOW TO USE:
#    1. Insert a "Python visual" from the Visualizations pane
#    2. Drag the required fields into the Values well (listed above each script)
#    3. Paste the script into the Python script editor
#    4. Click the ▶ Run button
#
#  REQUIREMENTS:
#    - Python 3.8+ with matplotlib, seaborn, pandas installed
#    - Power BI Desktop → File → Options → Python scripting →
#      set your Python home directory
#
#  THEME COLORS:
#    Campanelli = #0078D4 (blue)
#    Ericsson   = #00B7C3 (teal)
#    Job Site   = #107C10 (green)
#    Accent     = #8764B8 (purple)
# =====================================================================


# =====================================================================
#  VISUAL 1 — KPI Summary Cards (single Python visual)
# ---------------------------------------------------------------------
#  Values well: ActivityType, ActivityUser, ChildContainerName
#  (Power BI will pass the full dataset as 'dataset')
# =====================================================================

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import pandas as pd

df = dataset.copy()

total_activities   = len(df)
status_changes     = len(df[df['ActivityType'].isin(['Package Status Changed', 'Container Status Changed'])])
items_added        = len(df[df['ActivityType'] == 'Item Added to Container'])
unique_users       = df['ActivityUser'].nunique()
containers_touched = df['ChildContainerName'].dropna().nunique()

fig, axes = plt.subplots(1, 5, figsize=(14, 2.2))
fig.patch.set_facecolor('white')

kpis = [
    (total_activities,   'Total\nActivities',          '#0078D4'),
    (status_changes,     'Status\nChanges',            '#00B7C3'),
    (items_added,        'Items Added\nto Containers', '#107C10'),
    (unique_users,       'Active\nUsers',              '#8764B8'),
    (containers_touched, 'Containers\nTouched',        '#FF8C00'),
]

for ax, (val, label, color) in zip(axes, kpis):
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.text(0.5, 0.6, f'{val:,}', ha='center', va='center',
            fontsize=32, fontweight='bold', color=color)
    ax.text(0.5, 0.15, label, ha='center', va='center',
            fontsize=10, color='#444444', linespacing=1.3)
    ax.axis('off')

plt.tight_layout(pad=1.0)
plt.show()


# =====================================================================
#  VISUAL 2 — Activity by Day (clustered bar chart)
# ---------------------------------------------------------------------
#  Values well: ActivityDate, ActivityType
# =====================================================================

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import pandas as pd

df = dataset.copy()
df['ActivityDate'] = pd.to_datetime(df['ActivityDate'])

type_colors = {
    'Package Status Changed':       '#FF8C00',
    'Container Status Changed':     '#0078D4',
    'Item Added to Container':      '#107C10',
    'Package Archived / Unarchived':'#8764B8',
}

pivot = df.groupby([df['ActivityDate'].dt.strftime('%a %m/%d'), 'ActivityType']).size().unstack(fill_value=0)

# Sort by actual date
date_order = df.drop_duplicates('ActivityDate').sort_values('ActivityDate')
date_labels = date_order['ActivityDate'].dt.strftime('%a %m/%d').tolist()
pivot = pivot.reindex([d for d in date_labels if d in pivot.index])

fig, ax = plt.subplots(figsize=(8, 4))
fig.patch.set_facecolor('white')

bar_colors = [type_colors.get(c, '#CCCCCC') for c in pivot.columns]
pivot.plot(kind='bar', ax=ax, color=bar_colors, edgecolor='white', width=0.75)

ax.set_title('Activity by Day', fontsize=14, fontweight='bold', color='#333333', pad=12)
ax.set_xlabel('')
ax.set_ylabel('Count', fontsize=10, color='#666666')
ax.legend(fontsize=8, loc='upper left', framealpha=0.9)
ax.tick_params(axis='x', rotation=0, labelsize=9)
ax.tick_params(axis='y', labelsize=9)
ax.spines['top'].set_visible(False)
ax.spines['right'].set_visible(False)
ax.spines['left'].set_color('#DDDDDD')
ax.spines['bottom'].set_color('#DDDDDD')
ax.yaxis.grid(True, color='#F0F0F0', linewidth=0.8)
ax.set_axisbelow(True)

plt.tight_layout()
plt.show()


# =====================================================================
#  VISUAL 3 — Activity Breakdown (donut chart)
# ---------------------------------------------------------------------
#  Values well: ActivityType
# =====================================================================

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import pandas as pd

df = dataset.copy()

type_colors = {
    'Package Status Changed':       '#FF8C00',
    'Container Status Changed':     '#0078D4',
    'Item Added to Container':      '#107C10',
    'Package Archived / Unarchived':'#8764B8',
}

counts = df['ActivityType'].value_counts()
colors = [type_colors.get(t, '#CCCCCC') for t in counts.index]

fig, ax = plt.subplots(figsize=(5, 4))
fig.patch.set_facecolor('white')

wedges, texts, autotexts = ax.pie(
    counts.values, labels=None, colors=colors, autopct='%1.0f%%',
    startangle=90, pctdistance=0.78,
    wedgeprops=dict(width=0.4, edgecolor='white', linewidth=2))

for t in autotexts:
    t.set_fontsize(9)
    t.set_color('#333333')

ax.set_title('Activity Breakdown', fontsize=14, fontweight='bold',
             color='#333333', pad=12)

ax.legend(counts.index, loc='lower center', bbox_to_anchor=(0.5, -0.15),
          ncol=2, fontsize=8, frameon=False)

plt.tight_layout()
plt.show()


# =====================================================================
#  VISUAL 4 — Activity by Facility (horizontal stacked bar)
# ---------------------------------------------------------------------
#  Values well: EffectiveDisplayParentName, ActivityType
# =====================================================================

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import pandas as pd
import numpy as np

df = dataset.copy()

type_colors = {
    'Package Status Changed':       '#FF8C00',
    'Container Status Changed':     '#0078D4',
    'Item Added to Container':      '#107C10',
    'Package Archived / Unarchived':'#8764B8',
}

# Filter to rows that have a facility
df_fac = df[df['EffectiveDisplayParentName'].notna()].copy()
pivot = df_fac.groupby(['EffectiveDisplayParentName', 'ActivityType']).size().unstack(fill_value=0)

# Order facilities
fac_order = ['180 Campanelli', '6 Ericsson St', 'Job Site']
pivot = pivot.reindex([f for f in fac_order if f in pivot.index])

fig, ax = plt.subplots(figsize=(7, 3))
fig.patch.set_facecolor('white')

left = np.zeros(len(pivot))
for col in pivot.columns:
    color = type_colors.get(col, '#CCCCCC')
    ax.barh(pivot.index, pivot[col], left=left, color=color,
            edgecolor='white', height=0.55, label=col)
    left += pivot[col].values

ax.set_title('Activity by Facility', fontsize=14, fontweight='bold',
             color='#333333', pad=12)
ax.set_xlabel('Count', fontsize=10, color='#666666')
ax.legend(fontsize=8, loc='lower right', framealpha=0.9)
ax.tick_params(axis='y', labelsize=10)
ax.tick_params(axis='x', labelsize=9)
ax.spines['top'].set_visible(False)
ax.spines['right'].set_visible(False)
ax.spines['left'].set_color('#DDDDDD')
ax.spines['bottom'].set_color('#DDDDDD')
ax.xaxis.grid(True, color='#F0F0F0', linewidth=0.8)
ax.set_axisbelow(True)
ax.invert_yaxis()

plt.tight_layout()
plt.show()


# =====================================================================
#  VISUAL 5 — Activity Detail Table
# ---------------------------------------------------------------------
#  Values well: ActivityDate, ActivityUser, ActivityType, ItemName,
#               ProjectName, TrackingStatusName, ParentContainerName,
#               ChildContainerName, EffectiveDisplayParentName,
#               ChildContainerQrCode, PackageQrCode, ActivityDateTime
# =====================================================================

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import pandas as pd

df = dataset.copy()

# Sort newest first
if 'ActivityDateTime' in df.columns:
    df['ActivityDateTime'] = pd.to_datetime(df['ActivityDateTime'])
    df = df.sort_values('ActivityDateTime', ascending=False)

# ── CONFIG ───────────────────────────────────────────────────────────
MAX_ROWS      = 25        # fewer rows = bigger text; change as needed
FONT_DATA     = 10        # data cell font size
FONT_HEADER   = 11        # header font size
ROW_HEIGHT    = 1.8       # vertical scaling factor per row
FIG_WIDTH     = 24        # figure width in inches (Power BI stretches to fit)

# ── Select & rename columns ─────────────────────────────────────────
display_cols = [
    'ActivityDate', 'ActivityUser', 'ActivityType', 'ItemName',
    'ProjectName', 'TrackingStatusName',
    'ParentContainerName', 'ChildContainerName',
    'EffectiveDisplayParentName'
]
display_cols = [c for c in display_cols if c in df.columns]
df_show = df[display_cols].head(MAX_ROWS).copy()

col_labels = {
    'ActivityDate':              'Date',
    'ActivityUser':              'User',
    'ActivityType':              'Activity',
    'ItemName':                  'Item',
    'ProjectName':               'Project',
    'TrackingStatusName':        'Status',
    'ParentContainerName':       'Parent',
    'ChildContainerName':        'Child',
    'EffectiveDisplayParentName':'Facility',
}
df_show = df_show.rename(columns=col_labels)

# Format date column
if 'Date' in df_show.columns:
    df_show['Date'] = pd.to_datetime(df_show['Date']).dt.strftime('%m/%d')

# Replace "nan" with blank
df_show = df_show.fillna('')
for col in df_show.columns:
    df_show[col] = df_show[col].astype(str).replace('nan', '')

# Truncate long text so cells don't overflow
max_widths = {'Date': 6, 'User': 16, 'Activity': 22, 'Item': 28,
              'Project': 18, 'Status': 20, 'Parent': 18, 'Child': 18, 'Facility': 16}
for col in df_show.columns:
    limit = max_widths.get(col, 20)
    df_show[col] = df_show[col].str[:limit]

nrows, ncols = df_show.shape
fig_height = max(5, 0.45 * nrows + 2)
fig, ax = plt.subplots(figsize=(FIG_WIDTH, fig_height))
fig.patch.set_facecolor('white')
ax.axis('off')

# ── Proportional column widths ──────────────────────────────────────
col_widths = [0.04, 0.10, 0.14, 0.18, 0.12, 0.12, 0.11, 0.11, 0.08]
if len(col_widths) > ncols:
    col_widths = col_widths[:ncols]

# ── Row colors by activity type ─────────────────────────────────────
type_bg = {
    'Package Status Changed':       '#FFF4E6',
    'Container Status Changed':     '#E6F0FA',
    'Item Added to Container':      '#E6F2E6',
    'Package Archived / Unarchived':'#F3EFF8',
}

cell_colors = []
for _, row in df_show.iterrows():
    activity = str(row.get('Activity', ''))
    bg = type_bg.get(activity, '#FFFFFF')
    cell_colors.append([bg] * ncols)

table = ax.table(
    cellText=df_show.values,
    colLabels=df_show.columns,
    cellColours=cell_colors,
    colWidths=col_widths,
    loc='upper center',
    cellLoc='left'
)

table.auto_set_font_size(False)
table.set_fontsize(FONT_DATA)
table.scale(1, ROW_HEIGHT)

# ── Style header row ────────────────────────────────────────────────
for j in range(ncols):
    cell = table[0, j]
    cell.set_facecolor('#0078D4')
    cell.set_text_props(color='white', fontweight='bold', fontsize=FONT_HEADER)
    cell.set_edgecolor('#CCCCCC')
    cell.set_height(cell.get_height() * 1.3)

# ── Style data cells ────────────────────────────────────────────────
for i in range(1, nrows + 1):
    for j in range(ncols):
        cell = table[i, j]
        cell.set_edgecolor('#E8E8E8')
        cell.set_text_props(fontsize=FONT_DATA, color='#333333')

# ── Highlight shipped/received status cells ─────────────────────────
if 'Status' in df_show.columns:
    status_idx = list(df_show.columns).index('Status')
    for i, (_, row) in enumerate(df_show.iterrows(), start=1):
        status = str(row.get('Status', ''))
        if status in ('Shipped to Jobsite', 'Received on Jobsite'):
            table[i, status_idx].set_facecolor('#107C10')
            table[i, status_idx].set_text_props(color='white', fontweight='bold')
        elif status == 'Fabrication Complete':
            table[i, status_idx].set_facecolor('#00B7C3')
            table[i, status_idx].set_text_props(color='white', fontweight='bold')

ax.set_title(f'Weekly Activity Detail (latest {min(MAX_ROWS, len(df))} events)',
             fontsize=16, fontweight='bold', color='#333333', pad=16, loc='left')

plt.tight_layout()
plt.show()


# =====================================================================
#  VISUAL 6 — Activity Timeline / Heatmap
# ---------------------------------------------------------------------
#  Values well: ActivityDate, ActivityType
#  (Bonus visual — shows activity density across days and types)
# =====================================================================

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors
import pandas as pd
import numpy as np

df = dataset.copy()
df['ActivityDate'] = pd.to_datetime(df['ActivityDate'])

pivot = df.groupby([df['ActivityDate'].dt.strftime('%a %m/%d'), 'ActivityType']).size().unstack(fill_value=0)

# Sort by actual date
date_order = df.drop_duplicates('ActivityDate').sort_values('ActivityDate')
date_labels = date_order['ActivityDate'].dt.strftime('%a %m/%d').tolist()
pivot = pivot.reindex([d for d in date_labels if d in pivot.index])

fig, ax = plt.subplots(figsize=(8, 3))
fig.patch.set_facecolor('white')

cmap = mcolors.LinearSegmentedColormap.from_list('custom', ['#F5F5F5', '#0078D4'])
im = ax.imshow(pivot.values.T, aspect='auto', cmap=cmap, interpolation='nearest')

ax.set_xticks(range(len(pivot.index)))
ax.set_xticklabels(pivot.index, fontsize=9, rotation=0)
ax.set_yticks(range(len(pivot.columns)))
ax.set_yticklabels(pivot.columns, fontsize=8)

# Annotate cells
for i in range(pivot.shape[0]):
    for j in range(pivot.shape[1]):
        val = pivot.values[i, j]
        if val > 0:
            text_color = 'white' if val > pivot.values.max() * 0.6 else '#333333'
            ax.text(i, j, str(int(val)), ha='center', va='center',
                    fontsize=10, fontweight='bold', color=text_color)

ax.set_title('Activity Heatmap', fontsize=14, fontweight='bold',
             color='#333333', pad=12)

plt.colorbar(im, ax=ax, shrink=0.8, label='Count')
plt.tight_layout()
plt.show()
