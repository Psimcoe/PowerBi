// =====================================================================
//  Containers Hierarchy  –  API-sourced
//  ─────────────────────────────────────
//  Paste into Power BI → Home → Transform Data → New Blank Query →
//  Advanced Editor.
//
//  Pulls containers and packages directly from the GTP Stratus REST
//  API, then builds a FLAT display table:
//    EffectiveDisplayParent ▸ AreaRow ▸ Rack ▸ Shelf ▸
//    ChildContainer ▸ Package
//
//  No dependency on existing model tables.
// =====================================================================
let
    // ─── Configuration ──────────────────────────────────────────────
    _API_BASE   = "https://api.gtpstratus.com",
    _APP_KEY    = "8c729670-204f-4cb5-be17-de549ffd60d6",

    _JS_NAME    = "Job Site",
    _JS_ID      = "SYN-JOBSITE",
    _WH_NAME    = "180 Campanelli IR 6 Ericsson",
    _WH_ID      = "SYN-WAREHOUSE",
    _NO_PARENT  = "(No Parent Container)",
    _NO_CHILD   = "(No Child Container)",
    _NO_CONTAINER = "(No Container)",
    _NO_PKG     = "(No Package)",
    _DIRECT     = "(Directly on Parent)",
    _JS_UPPER   = {"SHIPPED TO JOBSITE", "RECEIVED ON JOBSITE"},
    _USE_WH     = true,
    _CHILD_TYPES = {"Cart", "Pallet", "Shipping", "Basket", "Box"},

    // ─── API helpers ────────────────────────────────────────────────
    _Headers = [#"app-key" = _APP_KEY],

    // Generic paged-fetch: returns all pages concatenated
    FetchAllPages = (endpoint as text, pageSize as number) as list =>
        let
            FirstPage = Json.Document(
                Web.Contents(_API_BASE, [
                    RelativePath = endpoint,
                    Query = [pagesize = Text.From(pageSize), page = "0"],
                    Headers = _Headers
                ])),
            Total     = FirstPage[total],
            PageCount = Number.RoundUp(Total / pageSize),
            Pages     = List.Generate(
                () => [i = 0, data = FirstPage[data]],
                each [i] < PageCount,
                each [
                    i = [i] + 1,
                    data = Json.Document(
                        Web.Contents(_API_BASE, [
                            RelativePath = endpoint,
                            Query = [
                                pagesize = Text.From(pageSize),
                                page     = Text.From([i] + 1)
                            ],
                            Headers = _Headers
                        ]))[data]
                ],
                each [data]
            ),
            AllData = List.Combine(Pages)
        in
            AllData,

    // ─── 1.  Load all containers ────────────────────────────────────
    RawContainers   = FetchAllPages("/v1/container", 1000),
    ContainersTable = Table.FromRecords(
        List.Transform(RawContainers, each Record.SelectFields(_, {
            "id", "name", "description", "location",
            "containerTypeName", "parentContainerId",
            "currentTrackingStatusId",
            "packageIds", "containerIds"
        })),
        type table [
            id = nullable text, name = nullable text,
            description = nullable text, location = nullable text,
            containerTypeName = nullable text,
            parentContainerId = nullable text,
            currentTrackingStatusId = nullable text,
            packageIds = nullable list, containerIds = nullable list
        ]
    ),

    // ─── 2.  Load all packages ──────────────────────────────────────
    RawPackages   = FetchAllPages("/v1/package", 200),
    PackagesTable = Table.FromRecords(
        List.Transform(RawPackages, each Record.SelectFields(_, {
            "id", "name", "statusName", "currentTrackingStatusId"
        })),
        type table [
            id = nullable text, name = nullable text,
            statusName = nullable text,
            currentTrackingStatusId = nullable text
        ]
    ),

    // ─── 3.  Load tracking statuses for display names ───────────────
    TrackingStatuses = Json.Document(
        Web.Contents(_API_BASE, [
            RelativePath = "/v1/company/tracking-statuses",
            Headers = _Headers
        ])),
    StatusLookup = Table.FromRecords(TrackingStatuses,
        type table [id = text, name = text]),

    // ─── 4.  Classify containers by role ────────────────────────────
    //  Role: TopArea | AreaRow | Rack | Shelf | Child
    A_Tagged = Table.AddColumn(ContainersTable, "Role", each
        let ct = [containerTypeName] in
        if ct = null then "TopArea"
        else if List.Contains(_CHILD_TYPES, ct)            then "Child"
        else if ct = "Shelf"                               then "Shelf"
        else if ct = "Rack"                                then "Rack"
        else if ct = "Area"
                and Text.Contains([name], "ROW",
                        Comparer.OrdinalIgnoreCase)        then "AreaRow"
        else                                                    "TopArea"
    ),

    // Add resolved tracking status name for containers
    A_Status = Table.NestedJoin(A_Tagged, {"currentTrackingStatusId"},
                   StatusLookup, {"id"}, "_ts", JoinKind.LeftOuter),
    A_WithStatus = Table.ExpandTableColumn(A_Status, "_ts",
                       {"name"}, {"TrackingStatusName"}),

    A_All = Table.Buffer(A_WithStatus),

    A_TopAreas  = Table.Buffer(Table.SelectRows(A_All, each [Role] = "TopArea")),
    A_AreaRows  = Table.Buffer(Table.SelectRows(A_All, each [Role] = "AreaRow")),
    A_Racks     = Table.Buffer(Table.SelectRows(A_All, each [Role] = "Rack")),
    A_Shelves   = Table.Buffer(Table.SelectRows(A_All, each [Role] = "Shelf")),
    A_Children  = Table.Buffer(Table.SelectRows(A_All, each [Role] = "Child")),

    A_RackNames    = List.Buffer(Table.Column(A_Racks, "name")),
    A_AreaRowNames = List.Buffer(Table.Column(A_AreaRows, "name")),

    // Main prefab area
    _PrefabAreas = Table.SelectRows(A_TopAreas,
        each [containerTypeName] = "Prefab Area"),
    _MainPrefab  = if Table.RowCount(_PrefabAreas) > 0
                   then _PrefabAreas{0}[name] else null,

    // ─── 5.  Naming-rule maps ───────────────────────────────────────
    //  Shelf → Rack  (shelf name starts with rack name; longest match)
    B_S2R = Table.Buffer(
        Table.SelectColumns(
            Table.AddColumn(A_Shelves, "_RackName", each
                let hits = List.Select(A_RackNames, (rn) =>
                        Text.StartsWith([name], rn,
                            Comparer.OrdinalIgnoreCase)),
                    best = if List.Count(hits) = 0 then null
                           else List.Last(List.Sort(hits, (a, b) =>
                               Value.Compare(Text.Length(a),
                                             Text.Length(b))))
                in best),
            {"name", "_RackName"})),

    //  Rack → AreaRow  (first letter ↔ "ROW <letter>")
    B_R2AR = Table.Buffer(
        Table.SelectColumns(
            Table.AddColumn(A_Racks, "_AreaRowName", each
                let letter = Text.Upper(Text.Start([name], 1)),
                    hits   = List.Select(A_AreaRowNames, (ar) =>
                        Text.Contains(ar, "ROW " & letter,
                            Comparer.OrdinalIgnoreCase))
                in if List.Count(hits) > 0 then hits{0} else null),
            {"name", "_AreaRowName"})),

    // ─── 6.  Container chain ────────────────────────────────────────
    //  Every container → (ChainTopArea, ChainAreaRow, ChainRack, ChainShelf)
    C1 = Table.NestedJoin(A_All, {"name"}, B_S2R, {"name"},
             "_s", JoinKind.LeftOuter),
    C2 = Table.ExpandTableColumn(C1, "_s", {"_RackName"}, {"_mRack"}),

    C3 = Table.AddColumn(C2, "_eRack", each
        if [Role] = "Rack" then [name] else [_mRack]),

    C4 = Table.NestedJoin(C3, {"_eRack"}, B_R2AR, {"name"},
             "_r", JoinKind.LeftOuter),
    C5 = Table.ExpandTableColumn(C4, "_r", {"_AreaRowName"}, {"_mAreaRow"}),

    C6 = Table.AddColumn(C5, "_eAreaRow", each
        if [Role] = "AreaRow" then [name] else [_mAreaRow]),

    C7 = Table.AddColumn(C6, "_eTopArea", each
        if [Role] = "TopArea"       then [name]
        else if [_eAreaRow] <> null then _MainPrefab
        else null),

    C8 = Table.AddColumn(C7, "_eShelf", each
        if [Role] = "Shelf" then [name] else null),

    Chain = Table.Buffer(
        Table.RenameColumns(
            Table.SelectColumns(C8,
                {"name", "id", "Role", "containerTypeName",
                 "TrackingStatusName", "parentContainerId",
                 "packageIds",
                 "_eTopArea", "_eAreaRow", "_eRack", "_eShelf"}),
            {{"_eTopArea", "ChainTopArea"}, {"_eAreaRow", "ChainAreaRow"},
             {"_eRack", "ChainRack"}, {"_eShelf", "ChainShelf"}})),

    // ─── 7.  Build container-to-container index (parentId) ──────────
    //  The API gives us parentContainerId directly — no Merge1 needed.
    //  Build lookup: containerId → parent container row
    ContainerIdIndex = Table.Buffer(
        Table.SelectColumns(Chain,
            {"id", "name", "Role", "containerTypeName",
             "ChainTopArea", "ChainAreaRow", "ChainRack", "ChainShelf",
             "TrackingStatusName"})),

    // ─── 8.  Expand package lists into rows ─────────────────────────
    //  Each container has a packageIds list.  Explode to 1 row per
    //  container × packageId pair.
    PkgExpanded = Table.ExpandListColumn(
        Table.SelectRows(Chain, each [packageIds] <> null
                                 and List.Count([packageIds]) > 0),
        "packageIds"),
    PkgRenamed = Table.RenameColumns(PkgExpanded, {{"packageIds", "pkgId"}}),

    // Join package details
    P1 = Table.NestedJoin(PkgRenamed, {"pkgId"}, PackagesTable, {"id"},
             "_pkg", JoinKind.LeftOuter),
    P2 = Table.ExpandTableColumn(P1, "_pkg",
        {"name", "statusName", "currentTrackingStatusId"},
        {"PkgName", "PkgStatusName", "PkgTrackingStatusId"}),

    // Resolve package tracking status name
    P3 = Table.NestedJoin(P2, {"PkgTrackingStatusId"}, StatusLookup, {"id"},
             "_pts", JoinKind.LeftOuter),
    P4 = Table.ExpandTableColumn(P3, "_pts", {"name"}, {"PkgTrackingName"}),

    // Use PkgStatusName if available, else PkgTrackingName
    P5 = Table.AddColumn(P4, "PkgStatus", each
        if [PkgStatusName] <> null then [PkgStatusName]
        else [PkgTrackingName]),

    // ─── 9.  Determine parent vs child for each container-pkg row ───
    //  The container that owns the packageIds could be the parent OR
    //  the child.  The child container has a parentContainerId → the parent.
    //  If the owning container is a Child type → look up its parent.
    //  If it's a TopArea/AreaRow/Rack/Shelf → it IS the parent.

    // For Child containers: look up parent via parentContainerId
    Q1 = Table.NestedJoin(P5, {"parentContainerId"}, ContainerIdIndex, {"id"},
             "_parent", JoinKind.LeftOuter),
    Q2 = Table.ExpandTableColumn(Q1, "_parent",
        {"name", "id", "Role", "ChainTopArea", "ChainAreaRow",
         "ChainRack", "ChainShelf", "TrackingStatusName"},
        {"ParentName", "ParentId", "ParentRole", "ParentTopArea",
         "ParentAreaRow", "ParentRack", "ParentShelf", "ParentStatusName"}),

    // Assign hierarchy columns based on role of the owning container
    Q3 = Table.AddColumn(Q2, "EffTopArea", each
        if [Role] = "Child" then [ParentTopArea]
        else [ChainTopArea]),
    Q4 = Table.AddColumn(Q3, "EffAreaRow", each
        if [Role] = "Child" then [ParentAreaRow]
        else [ChainAreaRow]),
    Q5 = Table.AddColumn(Q4, "EffRack", each
        if [Role] = "Child" then [ParentRack]
        else [ChainRack]),
    Q6 = Table.AddColumn(Q5, "EffShelf", each
        if [Role] = "Child" then [ParentShelf]
        else [ChainShelf]),

    // Parent container info
    Q7 = Table.AddColumn(Q6, "FinalParentName", each
        if [Role] = "Child" then [ParentName]
        else [name]),
    Q8 = Table.AddColumn(Q7, "FinalParentId", each
        if [Role] = "Child" then [ParentId]
        else [id]),

    // Child container info (only if owning container is a Child type)
    Q9  = Table.AddColumn(Q8, "ChildName", each
        if [Role] = "Child" then [name] else null),
    Q10 = Table.AddColumn(Q9, "ChildId", each
        if [Role] = "Child" then [id] else null),
    Q11 = Table.AddColumn(Q10, "ChildType", each
        if [Role] = "Child" then [containerTypeName] else null),
    Q12 = Table.AddColumn(Q11, "ChildStatus", each
        if [Role] = "Child" then [TrackingStatusName] else null),

    // RowKind
    Q13 = Table.AddColumn(Q12, "RowKind", each
        if [Role] = "Child" then "ChildPackage"
        else                     "ParentDirectPackage"),

    // ─── 10. EffectiveDisplayParent ─────────────────────────────────
    R1 = Table.AddColumn(Q13, "_pkgSU", each
        Text.Upper(Text.Trim(if [PkgStatus] <> null then [PkgStatus] else ""))),
    R2 = Table.AddColumn(R1, "_cSU", each
        Text.Upper(Text.Trim(if [ChildStatus] <> null then [ChildStatus] else ""))),

    R3 = Table.AddColumn(R2, "_isJS", each
        List.Contains(_JS_UPPER, [_pkgSU])
        or List.Contains(_JS_UPPER, [_cSU])),

    R4 = Table.AddColumn(R3, "EffectiveDisplayParentName", each
        if [_isJS]                   then _JS_NAME
        else if [EffTopArea] <> null then [EffTopArea]
        else if _USE_WH              then _WH_NAME
        else                              _NO_PARENT),

    R5 = Table.NestedJoin(R4, {"EffTopArea"}, A_TopAreas, {"name"},
             "_taJ", JoinKind.LeftOuter),
    R6 = Table.ExpandTableColumn(R5, "_taJ", {"id"}, {"_taId"}),

    R7 = Table.AddColumn(R6, "EffectiveDisplayParentId", each
        if [EffectiveDisplayParentName] = _JS_NAME    then _JS_ID
        else if [EffectiveDisplayParentName] = _WH_NAME then _WH_ID
        else if [EffectiveDisplayParentName] = _NO_PARENT then null
        else [_taId]),

    R8 = Table.AddColumn(R7, "RelationshipStatus", each
        if [_isJS]                  then "Status override: Job Site"
        else if [Role] = "Child" and [ParentName] <> null
                                    then "Direct assignment"
        else if [Role] <> "Child"   then "Direct assignment"
        else if _USE_WH             then "Warehouse fallback"
        else                             "No parent found"),

    // Display columns
    R9  = Table.AddColumn(R8, "ChildContainerName", each
        if [ChildName] <> null                        then [ChildName]
        else if [RowKind] = "ParentDirectPackage"     then _DIRECT
        else                                               _NO_CONTAINER),
    R10 = Table.AddColumn(R9, "DisplayStatus", each
        if [ChildName] <> null and [ChildStatus] <> null
            then [ChildStatus]
            else [PkgStatus]),
    R11 = Table.AddColumn(R10, "DisplayState", each null),

    PkgRows = Table.SelectColumns(R11, {
        "EffectiveDisplayParentId", "EffectiveDisplayParentName",
        "FinalParentId", "FinalParentName",
        "EffAreaRow", "EffRack", "EffShelf",
        "ChildId", "ChildContainerName", "ChildType",
        "PkgName", "RowKind", "RelationshipStatus",
        "DisplayStatus", "DisplayState"
    }),
    PkgRowsRenamed = Table.RenameColumns(PkgRows, {
        {"FinalParentId", "ParentContainerId"},
        {"FinalParentName", "ParentContainerName"},
        {"EffAreaRow", "AreaRowName"},
        {"EffRack", "RackName"},
        {"EffShelf", "ShelfName"},
        {"ChildId", "ChildContainerId"},
        {"ChildType", "ChildContainerType"},
        {"PkgName", "PackageName"}
    }),

    // ─── 11. UncontainedPackage rows ────────────────────────────────
    //  Packages that don't appear in ANY container's packageIds
    AllContainerPkgIds = List.Buffer(List.Distinct(
        List.Combine(
            List.Transform(
                Table.Column(
                    Table.SelectRows(ContainersTable,
                        each [packageIds] <> null),
                    "packageIds"),
                each _)))),

    UncontainedPkgs = Table.SelectRows(PackagesTable,
        each not List.Contains(AllContainerPkgIds, [id])),

    // Resolve their tracking status
    U1 = Table.NestedJoin(UncontainedPkgs, {"currentTrackingStatusId"},
             StatusLookup, {"id"}, "_ts", JoinKind.LeftOuter),
    U2 = Table.ExpandTableColumn(U1, "_ts", {"name"}, {"UPkgTrackingName"}),
    U3 = Table.AddColumn(U2, "UPkgStatus", each
        if [statusName] <> null then [statusName] else [UPkgTrackingName]),

    U4 = Table.AddColumn(U3, "_isJS", each
        List.Contains(_JS_UPPER,
            Text.Upper(Text.Trim(
                if [UPkgStatus] <> null then [UPkgStatus] else "")))),

    U5 = Table.AddColumn(U4, "EffectiveDisplayParentName", each
        if [_isJS]   then _JS_NAME
        else if _USE_WH then _WH_NAME
        else              _NO_PARENT),
    U6 = Table.AddColumn(U5, "EffectiveDisplayParentId", each
        if [EffectiveDisplayParentName] = _JS_NAME then _JS_ID
        else if [EffectiveDisplayParentName] = _WH_NAME then _WH_ID
        else null),

    // Build full records for uncontained packages
    UncontainedRecords = List.Transform(
        Table.ToRecords(U6),
        each [
            EffectiveDisplayParentId = [EffectiveDisplayParentId],
            EffectiveDisplayParentName = [EffectiveDisplayParentName],
            ParentContainerId = null,
            ParentContainerName = null,
            AreaRowName = null,
            RackName = null,
            ShelfName = null,
            ChildContainerId = null,
            ChildContainerName = _NO_CONTAINER,
            ChildContainerType = null,
            PackageName = [name],
            RowKind = "UncontainedPackage",
            RelationshipStatus =
                if [_isJS] then "Status override: Job Site"
                else if _USE_WH then "Warehouse fallback"
                else "No container",
            DisplayStatus = [UPkgStatus],
            DisplayState = null
        ]),
    UncontainedTable = Table.FromRecords(UncontainedRecords),

    // ─── 12. ChildNoPackage rows ────────────────────────────────────
    //  Child containers whose packageIds list is empty or null
    EmptyChildren = Table.SelectRows(A_Children,
        each [packageIds] = null or List.Count([packageIds]) = 0),

    // Look up their parent
    EC1 = Table.NestedJoin(EmptyChildren, {"parentContainerId"},
              ContainerIdIndex, {"id"}, "_p", JoinKind.LeftOuter),
    EC2 = Table.ExpandTableColumn(EC1, "_p",
        {"name", "id", "ChainTopArea", "ChainAreaRow",
         "ChainRack", "ChainShelf"},
        {"ECParentName", "ECParentId", "ECTopArea",
         "ECAreaRow", "ECRack", "ECShelf"}),

    EC3 = Table.AddColumn(EC2, "_isJS", each
        List.Contains(_JS_UPPER,
            Text.Upper(Text.Trim(
                if [TrackingStatusName] <> null then [TrackingStatusName] else "")))),

    EC4 = Table.AddColumn(EC3, "EffectiveDisplayParentName", each
        if [_isJS]                then _JS_NAME
        else if [ECTopArea] <> null then [ECTopArea]
        else if _USE_WH             then _WH_NAME
        else                             _NO_PARENT),

    EC5 = Table.NestedJoin(EC4, {"ECTopArea"}, A_TopAreas, {"name"},
              "_taJ", JoinKind.LeftOuter),
    EC6 = Table.ExpandTableColumn(EC5, "_taJ", {"id"}, {"_taId"}),

    EC7 = Table.AddColumn(EC6, "EffectiveDisplayParentId", each
        if [EffectiveDisplayParentName] = _JS_NAME    then _JS_ID
        else if [EffectiveDisplayParentName] = _WH_NAME then _WH_ID
        else if [EffectiveDisplayParentName] = _NO_PARENT then null
        else [_taId]),

    ChildNoPackageRecords = List.Transform(
        Table.ToRecords(EC7),
        each [
            EffectiveDisplayParentId = [EffectiveDisplayParentId],
            EffectiveDisplayParentName = [EffectiveDisplayParentName],
            ParentContainerId = [ECParentId],
            ParentContainerName = [ECParentName],
            AreaRowName = [ECAreaRow],
            RackName = [ECRack],
            ShelfName = [ECShelf],
            ChildContainerId = [id],
            ChildContainerName = [name],
            ChildContainerType = [containerTypeName],
            PackageName = _NO_PKG,
            RowKind = "ChildNoPackage",
            RelationshipStatus =
                if [_isJS] then "Status override: Job Site"
                else if [ECParentName] <> null then "Direct assignment"
                else if _USE_WH then "Warehouse fallback"
                else "No parent found",
            DisplayStatus = [TrackingStatusName],
            DisplayState = null
        ]),
    ChildNoPackageTable = Table.FromRecords(ChildNoPackageRecords),

    // ─── 13. ParentEmpty rows ───────────────────────────────────────
    //  TopArea containers that appear nowhere in the output
    UsedParents = List.Buffer(List.Distinct(List.Combine({
        Table.Column(PkgRowsRenamed, "EffectiveDisplayParentName"),
        if Table.RowCount(ChildNoPackageTable) > 0
            then Table.Column(ChildNoPackageTable, "EffectiveDisplayParentName")
            else {},
        if Table.RowCount(UncontainedTable) > 0
            then Table.Column(UncontainedTable, "EffectiveDisplayParentName")
            else {}
    }))),

    EmptyParents = Table.SelectRows(A_TopAreas,
        each not List.Contains(UsedParents, [name])),

    ParentEmptyRecords = List.Transform(
        Table.ToRecords(EmptyParents),
        each [
            EffectiveDisplayParentId = [id],
            EffectiveDisplayParentName = [name],
            ParentContainerId = [id],
            ParentContainerName = [name],
            AreaRowName = null,
            RackName = null,
            ShelfName = null,
            ChildContainerId = null,
            ChildContainerName = _NO_CHILD,
            ChildContainerType = null,
            PackageName = _NO_PKG,
            RowKind = "ParentEmpty",
            RelationshipStatus = "Empty parent",
            DisplayStatus = [TrackingStatusName],
            DisplayState = null
        ]),
    ParentEmptyTable = Table.FromRecords(ParentEmptyRecords),

    // ─── 14. Union all rows ─────────────────────────────────────────
    AllRows = Table.Combine({
        PkgRowsRenamed,
        UncontainedTable,
        ChildNoPackageTable,
        ParentEmptyTable
    }),

    // ─── 15. Final typing ───────────────────────────────────────────
    Typed = Table.TransformColumnTypes(AllRows, {
        {"EffectiveDisplayParentId",   type nullable text},
        {"EffectiveDisplayParentName", type text},
        {"ParentContainerId",          type nullable text},
        {"ParentContainerName",        type nullable text},
        {"AreaRowName",                type nullable text},
        {"RackName",                   type nullable text},
        {"ShelfName",                  type nullable text},
        {"ChildContainerId",           type nullable text},
        {"ChildContainerName",         type text},
        {"ChildContainerType",         type nullable text},
        {"PackageName",                type text},
        {"RowKind",                    type text},
        {"RelationshipStatus",         type text},
        {"DisplayStatus",              type nullable text},
        {"DisplayState",               type nullable text}
    })
in
    Typed
