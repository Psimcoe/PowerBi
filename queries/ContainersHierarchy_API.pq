// =====================================================================
//  Containers Hierarchy  –  API-sourced
//  ─────────────────────────────────────
//  Paste into Power BI → Home → Transform Data → New Blank Query →
//  Advanced Editor.
//
//  Pulls containers from the GTP Stratus REST API and references
//  the existing "Packages" query (Synapse) for package data.
//  Builds a FLAT display table:
//    EffectiveDisplayParent ▸ AreaRow ▸ Rack ▸ Shelf ▸
//    ChildContainer ▸ Package
//
//  Depends on: existing "Packages" query in the model.
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

    // ─── 2.  Reference existing Packages query ──────────────────────
    //  The model's "Packages" query (from Synapse) already has all
    //  package data.  "PackageContainer.1" gives the parent container name.
    //  "PackageContainer.2" (if present) gives the child container name.
    //  IMPORTANT: "Status_" = tracking status name (e.g. Shipped, etc.)
    //             "Status"  = lifecycle status (Active / Archived)
    _PkgRaw = Table.SelectColumns(Packages, {
        "Id", "Name", "Status", "Status_", "PackageTrackingStatusId",
        "PackageContainer.1", "PackageContainer.2"
    }),
    // Keep only Active packages
    _PkgActive = Table.SelectRows(_PkgRaw, each [Status] = "Active"),
    PackagesTable = Table.RenameColumns(
        _PkgActive,
        {{"Id", "id"}, {"Name", "name"}, {"Status_", "statusName"},
         {"PackageTrackingStatusId", "currentTrackingStatusId"}}
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

    // ─── 8.  Join packages to containers via PackageContainer.1 ─────
    //  Each package has "PackageContainer.1" = the parent/area container name.
    //  "PackageContainer.2" (trimmed) = the child container name if present.
    //  Rename package columns first to avoid collision with container cols.
    PkgPrep0 = Table.SelectRows(PackagesTable,
        each [#"PackageContainer.1"] <> null
         and [#"PackageContainer.1"] <> ""),
    // Trim PackageContainer.2 (has leading space from CSV split)
    PkgPrep1 = Table.TransformColumns(PkgPrep0,
        {{"PackageContainer.2", each Text.Trim(_ ?? ""), type nullable text}}),
    PkgPrep = Table.RenameColumns(PkgPrep1,
        {{"id", "PkgId"}, {"name", "PkgName"},
         {"statusName", "PkgStatusName"},
         {"currentTrackingStatusId", "PkgTrackingStatusId"}}),

    // Join packages → Chain (containers) by PackageContainer.1 name
    // Inner join: unmatched packages flow to §11 (UncontainedPackage)
    PkgJoin = Table.NestedJoin(PkgPrep, {"PackageContainer.1"},
        Chain, {"name"}, "_cont", JoinKind.Inner),
    P2 = Table.ExpandTableColumn(PkgJoin, "_cont",
        {"name", "id", "Role", "containerTypeName",
         "TrackingStatusName", "parentContainerId",
         "ChainTopArea", "ChainAreaRow", "ChainRack", "ChainShelf"},
        {"name", "id", "Role", "containerTypeName",
         "TrackingStatusName", "parentContainerId",
         "ChainTopArea", "ChainAreaRow", "ChainRack", "ChainShelf"}),

    // Resolve package tracking status name
    P3 = Table.NestedJoin(P2, {"PkgTrackingStatusId"}, StatusLookup, {"id"},
             "_pts", JoinKind.LeftOuter),
    P4 = Table.ExpandTableColumn(P3, "_pts", {"name"}, {"PkgTrackingName"}),

    // Use PkgStatusName if available, else PkgTrackingName
    P5 = Table.AddColumn(P4, "PkgStatus", each
        if [PkgStatusName] <> null then [PkgStatusName]
        else [PkgTrackingName]),

    // ─── 9.  Determine parent vs child for each container-pkg row ───
    //  PackageContainer.1 = the matched container from Chain.
    //  PackageContainer.2 = child container name (if comma-separated).
    //  When .2 is present, .1 is the parent area and .2 is the child.

    // Resolve PackageContainer.2 → child container details from Chain
    P6 = Table.NestedJoin(P5, {"PackageContainer.2"}, Chain, {"name"},
             "_child2", JoinKind.LeftOuter),
    P7 = Table.ExpandTableColumn(P6, "_child2",
        {"name", "id", "containerTypeName", "TrackingStatusName"},
        {"Child2Name", "Child2Id", "Child2Type", "Child2Status"}),

    // Determine if .2 matched a known container
    P8 = Table.AddColumn(P7, "_has2", each
        [#"PackageContainer.2"] <> null
        and [#"PackageContainer.2"] <> ""
        and [Child2Name] <> null),

    // For Child-role containers (no .2): look up parent via parentContainerId
    Q1 = Table.NestedJoin(P8, {"parentContainerId"}, ContainerIdIndex, {"id"},
             "_parent", JoinKind.LeftOuter),
    Q2 = Table.ExpandTableColumn(Q1, "_parent",
        {"name", "id", "Role", "ChainTopArea", "ChainAreaRow",
         "ChainRack", "ChainShelf", "TrackingStatusName"},
        {"ParentName", "ParentId", "ParentRole", "ParentTopArea",
         "ParentAreaRow", "ParentRack", "ParentShelf", "ParentStatusName"}),

    // Assign hierarchy columns based on role of the owning container
    //  If _has2: .1 is the parent (TopArea), use its chain columns directly
    //  If Role=Child: use parent lookup columns
    //  Otherwise: use the matched container's chain columns
    Q3 = Table.AddColumn(Q2, "EffTopArea", each
        if [_has2]          then [ChainTopArea]
        else if [Role] = "Child" then [ParentTopArea]
        else [ChainTopArea]),
    Q4 = Table.AddColumn(Q3, "EffAreaRow", each
        if [_has2]          then [ChainAreaRow]
        else if [Role] = "Child" then [ParentAreaRow]
        else [ChainAreaRow]),
    Q5 = Table.AddColumn(Q4, "EffRack", each
        if [_has2]          then [ChainRack]
        else if [Role] = "Child" then [ParentRack]
        else [ChainRack]),
    Q6 = Table.AddColumn(Q5, "EffShelf", each
        if [_has2]          then [ChainShelf]
        else if [Role] = "Child" then [ParentShelf]
        else [ChainShelf]),

    // Parent container info
    Q7 = Table.AddColumn(Q6, "FinalParentName", each
        if [_has2]          then [name]        // .1 container = parent
        else if [Role] = "Child" then [ParentName]
        else [name]),
    Q8 = Table.AddColumn(Q7, "FinalParentId", each
        if [_has2]          then [id]
        else if [Role] = "Child" then [ParentId]
        else [id]),

    // Child container info
    //  _has2 → use the resolved .2 container
    //  Role=Child → use the .1 container (it IS the child)
    //  Otherwise → no child (ParentDirectPackage)
    Q9  = Table.AddColumn(Q8, "ChildName", each
        if [_has2]          then [Child2Name]
        else if [Role] = "Child" then [name] else null),
    Q10 = Table.AddColumn(Q9, "ChildId", each
        if [_has2]          then [Child2Id]
        else if [Role] = "Child" then [id] else null),
    Q11 = Table.AddColumn(Q10, "ChildType", each
        if [_has2]          then [Child2Type]
        else if [Role] = "Child" then [containerTypeName] else null),
    Q12 = Table.AddColumn(Q11, "ChildStatus", each
        if [_has2]          then [Child2Status]
        else if [Role] = "Child" then [TrackingStatusName] else null),

    // RowKind
    Q13 = Table.AddColumn(Q12, "RowKind", each
        if [_has2]          then "ChildPackage"
        else if [Role] = "Child" then "ChildPackage"
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
    //  Packages whose PackageContainer.1 is blank or doesn't match
    //  any known container name.
    AllContainerNames = List.Buffer(List.Distinct(
        Table.Column(Chain, "name"))),

    UncontainedPkgs = Table.SelectRows(PackagesTable,
        each [#"PackageContainer.1"] = null
          or [#"PackageContainer.1"] = ""
          or not List.Contains(AllContainerNames, [#"PackageContainer.1"])),

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
    //  Child containers whose name doesn't appear in any package's
    //  PackageContainer.1  (i.e. they hold no packages).
    AllPkgContainerNames = List.Buffer(List.Distinct(
        Table.Column(
            Table.SelectRows(PackagesTable,
                each [#"PackageContainer.1"] <> null
                 and [#"PackageContainer.1"] <> ""),
            "PackageContainer.1"))),

    EmptyChildren = Table.SelectRows(A_Children,
        each not List.Contains(AllPkgContainerNames, [name])),

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
