// =====================================================================
//  Weekly Container Activity  –  API-sourced
//  ───────────────────────────────────────────
//  Paste into Power BI → Home → Transform Data → New Blank Query →
//  Advanced Editor.
//
//  Pulls the latest 7 days of activity from the GTP Stratus REST API
//  and joins it to the ContainersHierarchy_API query to give
//  container context for each event.
//
//  Output columns:
//    ActivityDate, ActivityDay, ActivityUser, ActionName, Route,
//    ItemName, ItemType, ProjectName, ProjectNumber,
//    TrackingStatusName, TrackingStatusColor,
//    ParentContainerName, ChildContainerName,
//    EffectiveDisplayParentName, PackageName,
//    ParentContainerQrCode, ChildContainerQrCode, PackageQrCode
//
//  Depends on: existing "ContainersHierarchy_API" query in the model.
// =====================================================================
let
    // ─── Configuration ──────────────────────────────────────────────
    _API_BASE   = "https://api.gtpstratus.com",
    _APP_KEY    = "8c729670-204f-4cb5-be17-de549ffd60d6",
    _Headers    = [#"app-key" = _APP_KEY],

    // How many days of history to keep (default 7 = one week)
    _LOOKBACK_DAYS = 7,
    _Cutoff        = DateTime.From(Date.AddDays(Date.From(DateTime.LocalNow()), -_LOOKBACK_DAYS)),

    // The routes we care about for container / package activity
    _RELEVANT_ROUTES = {
        "Containers/add-item-to-container",
        "ContainersAssign/post-tracking-status-to-container",
        "Orders/post-tracking-status-to-package",
        "Orders/toggle-archive-package"
    },

    // ─── Paged fetch — stops when records are older than cutoff ─────
    //  The API returns activities newest-first.  We page forward
    //  and stop as soon as the oldest record on a page predates
    //  the cutoff, then we post-filter to exactly _LOOKBACK_DAYS.
    _PageSize = 1000,

    FetchRecentActivities = () as list =>
        let
            FirstRaw = Json.Document(
                Web.Contents(_API_BASE, [
                    RelativePath = "/v1/activity",
                    Query = [pagesize = Text.From(_PageSize), page = "0"],
                    Headers = _Headers
                ])),
            Total     = FirstRaw[total],
            PageCount = Number.RoundUp(Total / _PageSize),
            Pages = List.Generate(
                () => [i = 0, data = FirstRaw[data], stop = false],
                each [i] < PageCount and not [stop],
                each let
                    nextPage = [i] + 1,
                    raw = Json.Document(
                        Web.Contents(_API_BASE, [
                            RelativePath = "/v1/activity",
                            Query = [
                                pagesize = Text.From(_PageSize),
                                page     = Text.From(nextPage)
                            ],
                            Headers = _Headers
                        ])),
                    pageData = raw[data],
                    // Stop if the last record on the page is before the cutoff
                    oldest = if List.Count(pageData) > 0
                             then DateTime.From(List.Last(pageData)[createdDT])
                             else _Cutoff
                in [
                    i    = nextPage,
                    data = pageData,
                    stop = oldest < _Cutoff
                ],
                each [data]
            ),
            AllData = List.Combine(Pages)
        in
            AllData,

    RawActivities = FetchRecentActivities(),

    // ─── Build table & type ─────────────────────────────────────────
    ActivitiesTable = Table.FromRecords(
        List.Transform(RawActivities, each [
            id                   = Record.FieldOrDefault(_, "id", null),
            createdDT            = Record.FieldOrDefault(_, "createdDT", null),
            createdByName        = Record.FieldOrDefault(_, "createdByName", null),
            route                = Record.FieldOrDefault(_, "route", null),
            projectName          = Record.FieldOrDefault(_, "projectName", null),
            projectNumber        = Record.FieldOrDefault(_, "projectNumber", null),
            referenceName        = Record.FieldOrDefault(_, "referenceName", null),
            actionName           = Record.FieldOrDefault(_, "actionName", null),
            name                 = Record.FieldOrDefault(_, "name", null),
            value                = Record.FieldOrDefault(_, "value", null),
            trackingStatusName   = Record.FieldOrDefault(_, "trackingStatusName", null),
            trackingStatusColor  = Record.FieldOrDefault(_, "trackingStatusColor", null),
            divisionName         = Record.FieldOrDefault(_, "divisionName", null)
        ]),
        type table [
            id = nullable text, createdDT = nullable text,
            createdByName = nullable text, route = nullable text,
            projectName = nullable text, projectNumber = nullable text,
            referenceName = nullable text, actionName = nullable text,
            name = nullable text, value = nullable text,
            trackingStatusName = nullable text,
            trackingStatusColor = nullable text,
            divisionName = nullable text
        ]
    ),

    // ─── Parse datetime & filter to window ──────────────────────────
    WithDT = Table.TransformColumns(ActivitiesTable,
        {{"createdDT", each DateTime.From(_), type nullable datetime}}),

    InWindow = Table.SelectRows(WithDT, each [createdDT] >= _Cutoff),

    // ─── Filter to relevant routes ──────────────────────────────────
    Relevant = Table.SelectRows(InWindow,
        each List.Contains(_RELEVANT_ROUTES, [route])),

    // ─── Friendly route labels ──────────────────────────────────────
    WithRouteLabel = Table.AddColumn(Relevant, "ActivityType", each
        if [route] = "Containers/add-item-to-container"
            then "Item Added to Container"
        else if [route] = "ContainersAssign/post-tracking-status-to-container"
            then "Container Status Changed"
        else if [route] = "Orders/post-tracking-status-to-package"
            then "Package Status Changed"
        else if [route] = "Orders/toggle-archive-package"
            then "Package Archived / Unarchived"
        else [route]),

    // ─── Join to hierarchy to get container context ─────────────────
    //  Match by PackageName — the activity "name" field is the
    //  package or assembly name.
    Hierarchy = Table.Buffer(
        Table.SelectColumns(ContainersHierarchy_API, {
            "PackageName", "ParentContainerName", "ChildContainerName",
            "EffectiveDisplayParentName",
            "ParentContainerQrCode", "ChildContainerQrCode", "PackageQrCode"
        })),

    // De-duplicate hierarchy (a package can appear in multiple rows
    // if it's on a child container; take the first match)
    HierarchyDedup = Table.Buffer(
        Table.Distinct(Hierarchy, {"PackageName"})),

    J1 = Table.NestedJoin(WithRouteLabel, {"name"},
             HierarchyDedup, {"PackageName"}, "_hier", JoinKind.LeftOuter),
    J2 = Table.ExpandTableColumn(J1, "_hier",
        {"ParentContainerName", "ChildContainerName",
         "EffectiveDisplayParentName",
         "ParentContainerQrCode", "ChildContainerQrCode", "PackageQrCode"},
        {"ParentContainerName", "ChildContainerName",
         "EffectiveDisplayParentName",
         "ParentContainerQrCode", "ChildContainerQrCode", "PackageQrCode"}),

    // ─── Add date-only column for grouping / slicing ────────────────
    WithDate = Table.AddColumn(J2, "ActivityDate",
        each Date.From([createdDT]), type date),
    WithDay = Table.AddColumn(WithDate, "ActivityDay",
        each Date.DayOfWeekName(Date.From([createdDT])), type text),

    // ─── Select & rename final columns ──────────────────────────────
    Final = Table.SelectColumns(WithDay, {
        "createdDT", "ActivityDate", "ActivityDay",
        "createdByName", "actionName", "ActivityType", "route",
        "name", "referenceName",
        "projectName", "projectNumber",
        "trackingStatusName", "trackingStatusColor",
        "divisionName",
        "ParentContainerName", "ChildContainerName",
        "EffectiveDisplayParentName",
        "ParentContainerQrCode", "ChildContainerQrCode", "PackageQrCode"
    }),

    Renamed = Table.RenameColumns(Final, {
        {"createdDT",       "ActivityDateTime"},
        {"createdByName",   "ActivityUser"},
        {"actionName",      "ActionName"},
        {"route",           "Route"},
        {"name",            "ItemName"},
        {"referenceName",   "ItemType"},
        {"projectName",     "ProjectName"},
        {"projectNumber",   "ProjectNumber"},
        {"trackingStatusName",  "TrackingStatusName"},
        {"trackingStatusColor", "TrackingStatusColor"},
        {"divisionName",    "DivisionName"}
    }),

    // ─── Final typing ───────────────────────────────────────────────
    Typed = Table.TransformColumnTypes(Renamed, {
        {"ActivityDateTime",           type datetime},
        {"ActivityDate",               type date},
        {"ActivityDay",                type text},
        {"ActivityUser",               type nullable text},
        {"ActionName",                 type text},
        {"ActivityType",               type text},
        {"Route",                      type text},
        {"ItemName",                   type nullable text},
        {"ItemType",                   type nullable text},
        {"ProjectName",                type nullable text},
        {"ProjectNumber",              type nullable text},
        {"TrackingStatusName",         type nullable text},
        {"TrackingStatusColor",        type nullable text},
        {"DivisionName",               type nullable text},
        {"ParentContainerName",        type nullable text},
        {"ChildContainerName",         type nullable text},
        {"EffectiveDisplayParentName", type nullable text},
        {"ParentContainerQrCode",      type nullable text},
        {"ChildContainerQrCode",       type nullable text},
        {"PackageQrCode",              type nullable text}
    })
in
    Typed
