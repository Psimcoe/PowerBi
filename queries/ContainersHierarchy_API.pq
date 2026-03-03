// =====================================================================
//  Containers Hierarchy  –  API-sourced
//  ─────────────────────────────────────
//  Paste into Power BI → Home → Transform Data → New Blank Query →
//  Advanced Editor.
//
//  Pulls containers from the GTP Stratus REST API and references
//  the existing "Packages", "Containers", and
//  "ContainerTrackingUpdates" queries (Synapse) in the model.
//  Builds a FLAT display table:
//    EffectiveDisplayParent ▸ AreaRow ▸ Rack ▸ Shelf ▸
//    ChildContainer ▸ Package
//
//  Depends on: existing "Packages", "Containers", and
//              "ContainerTrackingUpdates" queries in the model.
// =====================================================================
let
    // ─── Configuration ──────────────────────────────────────────────
    _API_BASE   = "https://api.gtpstratus.com",
    _APP_KEY    = "8c729670-204f-4cb5-be17-de549ffd60d6",

    _JS_NAME    = "Job Site",
    _JS_ID      = "SYN-JOBSITE",
    _CAMP_NAME  = "180 Campanelli",
    _CAMP_ID    = "SYN-180CAMP",
    _ERIC_NAME  = "6 Ericsson St",
    _ERIC_ID    = "SYN-6ERIC",
    _NO_PARENT  = "(No Parent Container)",
    _NO_CHILD   = "(No Child Container)",
    _NO_CONTAINER = "(No Container)",
    _NO_PKG     = "(No Package)",
    _DIRECT     = "(Directly on Parent)",
    _NOT_USED   = "Not Physically Used Yet",
    _JS_UPPER   = {"SHIPPED TO JOBSITE", "RECEIVED ON JOBSITE"},
    _CHILD_TYPES = {"Cart", "Pallet", "Shipping", "Basket", "Box", "Container"},

    // Facility classification — which TopArea container names belong where
    _CAMP_ROOTS = {"180 CAMPANELLI - PREFAB", "180 Campanelli Warehouse",
                   "666999STG-180 CAMPANELLI PARKWAY STOUGHTON"},
    _ERIC_ROOTS = {"6 ERICSSON ST", "999999RRR-6 ERICSSON  ST. DORCHESTER"},

    // Convert a TopArea name to a display facility name.
    // Only 3 top-level groups: 180 Campanelli, 6 Ericsson St, Job Site.
    // Project containers (not in _CAMP_ROOTS / _ERIC_ROOTS) are mapped
    // to a warehouse via the TopArea's location field.  They move to
    // "Job Site" only when their tracking status is shipped/received
    // (handled by the _isJS flag at each call site).
    _FacilityName = (topArea as nullable text, topAreaLocation as nullable text) as text =>
        if topArea <> null and List.Contains(_CAMP_ROOTS, topArea)
            then _CAMP_NAME
        else if topArea <> null and List.Contains(_ERIC_ROOTS, topArea)
            then _ERIC_NAME
        else if topArea <> null then _FacilityFromLocation(topAreaLocation)
        else _CAMP_NAME,                          // Orphan fallback

    // Convert a facility display name to its synthetic ID
    _FacilityId = (facilityName as text, resolvedId as nullable text) as nullable text =>
        if facilityName = _JS_NAME   then _JS_ID
        else if facilityName = _CAMP_NAME then _CAMP_ID
        else if facilityName = _ERIC_NAME then _ERIC_ID
        else if facilityName = _NO_PARENT then null
        else resolvedId,

    // Determine facility from a container's location field (orphan fallback)
    _FacilityFromLocation = (loc as nullable text) as text =>
        let locU = Text.Upper(loc ?? "")
        in  if Text.Contains(locU, "ERICSSON") then _ERIC_NAME
            else _CAMP_NAME,

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
            "qrCodeUrl",
            "packageIds", "containerIds"
        })),
        type table [
            id = nullable text, name = nullable text,
            description = nullable text, location = nullable text,
            containerTypeName = nullable text,
            parentContainerId = nullable text,
            currentTrackingStatusId = nullable text,
            qrCodeUrl = nullable text,
            packageIds = nullable list, containerIds = nullable list
        ]
    ),

    // Container name → QR code lookup (used at the end to enrich rows)
    ContainerQrLookup = Table.Buffer(
        Table.SelectColumns(ContainersTable, {"name", "qrCodeUrl"})),

    // Package name → QR code lookup (fetched from API; Synapse doesn't carry qrCodeUrl)
    RawPackagesForQr  = FetchAllPages("/v1/package", 1000),
    PackageQrLookup   = Table.Buffer(Table.FromRecords(
        List.Transform(RawPackagesForQr, each [
            name      = Record.FieldOrDefault(_, "name", null),
            qrCodeUrl = Record.FieldOrDefault(_, "qrCodeUrl", null)
        ]),
        type table [name = nullable text, qrCodeUrl = nullable text])),

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

    // ─── 2b. Container dates from model ─────────────────────────────
    //  "Containers" table (Synapse) has CreatedDT per container.
    //  "ContainerTrackingUpdates" records every status change with a
    //  timestamp — we group by ContainerId to get the latest change.
    _ContainerDates = Table.SelectColumns(
        #"Containers", {"Id", "CreatedDT"}),
    _ContainerDatesR = Table.Buffer(Table.RenameColumns(
        _ContainerDates,
        {{"Id", "cId"}, {"CreatedDT", "ContainerCreatedDT"}})),

    _CTU = Table.SelectColumns(
        ContainerTrackingUpdates, {"ContainerId", "CreatedDT"}),
    _CTU_Grouped = Table.Buffer(Table.Group(
        _CTU, {"ContainerId"}, {
            {"LastStatusChangeDT", each List.Max([CreatedDT]),
             type nullable datetime}})),

    // Latest child-container creation date per parent
    //  (used for "duration since last child was added" on parent rows)
    _AllApiWithCreated = Table.ExpandTableColumn(
        Table.NestedJoin(
            Table.SelectColumns(ContainersTable,
                {"id", "parentContainerId"}),
            {"id"}, _ContainerDatesR, {"cId"},
            "_cd", JoinKind.LeftOuter),
        "_cd", {"ContainerCreatedDT"}, {"_cDT"}),
    _ParentedOnly = Table.SelectRows(_AllApiWithCreated,
        each [parentContainerId] <> null),
    _LatestChildCreated = Table.Buffer(Table.Group(
        Table.SelectColumns(_ParentedOnly,
            {"parentContainerId", "_cDT"}),
        {"parentContainerId"},
        {{"LatestChildCreatedDT", each List.Max([_cDT]),
          type nullable datetime}})),

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

    //  AreaRow → TopArea via parentContainerId
    //  (replaces the old _MainPrefab heuristic)
    B_AR2TA = Table.Buffer(
        Table.SelectColumns(
            Table.ExpandTableColumn(
                Table.NestedJoin(A_AreaRows, {"parentContainerId"},
                    A_TopAreas, {"id"}, "_p", JoinKind.LeftOuter),
                "_p", {"name"}, {"_TopAreaName"}),
            {"name", "_TopAreaName"})),

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

    // Resolve TopArea via AreaRow → parent (replaces _MainPrefab)
    C6b = Table.NestedJoin(C6, {"_eAreaRow"}, B_AR2TA, {"name"},
              "_arTA", JoinKind.LeftOuter),
    C6c = Table.ExpandTableColumn(C6b, "_arTA",
              {"_TopAreaName"}, {"_mTopArea"}),

    C7 = Table.AddColumn(C6c, "_eTopArea", each
        if [Role] = "TopArea" then [name]
        else [_mTopArea]),

    C8 = Table.AddColumn(C7, "_eShelf", each
        if [Role] = "Shelf" then [name] else null),

    Chain = Table.Buffer(
        Table.RenameColumns(
            Table.SelectColumns(C8,
                {"name", "id", "Role", "containerTypeName",
                 "TrackingStatusName", "parentContainerId",
                 "packageIds", "location",
                 "_eTopArea", "_eAreaRow", "_eRack", "_eShelf"}),
            {{"_eTopArea", "ChainTopArea"}, {"_eAreaRow", "ChainAreaRow"},
             {"_eRack", "ChainRack"}, {"_eShelf", "ChainShelf"}})),

    // ─── 7.  Build container-to-container index (parentId) ──────────
    ContainerIdIndex = Table.Buffer(
        Table.SelectColumns(Chain,
            {"id", "name", "Role", "containerTypeName",
             "ChainTopArea", "ChainAreaRow", "ChainRack", "ChainShelf",
             "TrackingStatusName"})),

    // ─── 8.  Join packages to containers via PackageContainer.1 ─────
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

    P5 = Table.AddColumn(P4, "PkgStatus", each
        if [PkgStatusName] <> null then [PkgStatusName]
        else [PkgTrackingName]),

    // ─── 9.  Determine parent vs child for each container-pkg row ───
    P6 = Table.NestedJoin(P5, {"PackageContainer.2"}, Chain, {"name"},
             "_child2", JoinKind.LeftOuter),
    P7 = Table.ExpandTableColumn(P6, "_child2",
        {"name", "id", "containerTypeName", "TrackingStatusName"},
        {"Child2Name", "Child2Id", "Child2Type", "Child2Status"}),

    P8 = Table.AddColumn(P7, "_has2", each
        [#"PackageContainer.2"] <> null
        and [#"PackageContainer.2"] <> ""
        and [Child2Name] <> null),

    Q1 = Table.NestedJoin(P8, {"parentContainerId"}, ContainerIdIndex, {"id"},
             "_parent", JoinKind.LeftOuter),
    Q2 = Table.ExpandTableColumn(Q1, "_parent",
        {"name", "id", "Role", "ChainTopArea", "ChainAreaRow",
         "ChainRack", "ChainShelf", "TrackingStatusName"},
        {"ParentName", "ParentId", "ParentRole", "ParentTopArea",
         "ParentAreaRow", "ParentRack", "ParentShelf", "ParentStatusName"}),

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

    Q7 = Table.AddColumn(Q6, "FinalParentName", each
        if [_has2]          then [name]
        else if [Role] = "Child" then [ParentName]
        else [name]),
    Q8 = Table.AddColumn(Q7, "FinalParentId", each
        if [_has2]          then [id]
        else if [Role] = "Child" then [ParentId]
        else [id]),

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

    Q13 = Table.AddColumn(Q12, "RowKind", each
        if [_has2]          then "ChildPackage"
        else if [Role] = "Child" then "ChildPackage"
        else                     "ParentDirectPackage"),

    // ─── 10. EffectiveDisplayParent ─────────────────────────────────
    R1 = Table.AddColumn(Q13, "_pkgSU", each
        Text.Upper(Text.Trim(if [PkgStatus] <> null then [PkgStatus] else ""))),
    R2 = Table.AddColumn(R1, "_cSU", each
        Text.Upper(Text.Trim(if [ChildStatus] <> null then [ChildStatus] else ""))),

    // Join TopArea to get its id, location, and tracking status
    R3b = Table.NestedJoin(R2, {"EffTopArea"}, A_TopAreas, {"name"},
              "_taJ", JoinKind.LeftOuter),
    R3c = Table.ExpandTableColumn(R3b, "_taJ",
              {"id", "location", "TrackingStatusName"},
              {"_taId", "_taLocation", "_taStatus"}),

    // Job Site if pkg, child, OR the TopArea itself is shipped/received
    R3 = Table.AddColumn(R3c, "_isJS", each
        let taSU = Text.Upper(Text.Trim(if [_taStatus] <> null then [_taStatus] else ""))
        in  List.Contains(_JS_UPPER, [_pkgSU])
            or List.Contains(_JS_UPPER, [_cSU])
            or List.Contains(_JS_UPPER, taSU)),

    R4 = Table.AddColumn(R3, "EffectiveDisplayParentName", each
        if [_isJS]                   then _JS_NAME
        else if [EffTopArea] <> null then _FacilityName([EffTopArea], [_taLocation])
        else                              _CAMP_NAME),

    R7 = Table.AddColumn(R4, "EffectiveDisplayParentId", each
        _FacilityId([EffectiveDisplayParentName], [_taId])),

    R8 = Table.AddColumn(R7, "RelationshipStatus", each
        if [_isJS]                  then "Status override: Job Site"
        else if [Role] = "Child" and [ParentName] <> null
                                    then "Direct assignment"
        else if [Role] <> "Child"   then "Direct assignment"
        else                             _CAMP_NAME & " fallback"),

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
    AllContainerNames = List.Buffer(List.Distinct(
        Table.Column(Chain, "name"))),

    UncontainedPkgs = Table.SelectRows(PackagesTable,
        each [#"PackageContainer.1"] = null
          or [#"PackageContainer.1"] = ""
          or not List.Contains(AllContainerNames, [#"PackageContainer.1"])),

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
        else              _CAMP_NAME),
    U6 = Table.AddColumn(U5, "EffectiveDisplayParentId", each
        _FacilityId([EffectiveDisplayParentName], null)),

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
                else _CAMP_NAME & " fallback",
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

    // Join TopArea to get its id, location, and tracking status
    EC3b = Table.NestedJoin(EC2, {"ECTopArea"}, A_TopAreas, {"name"},
               "_taJ", JoinKind.LeftOuter),
    EC3c = Table.ExpandTableColumn(EC3b, "_taJ",
               {"id", "location", "TrackingStatusName"},
               {"_taId", "_taLocation", "_taStatus"}),

    // Job Site if child container OR its TopArea is shipped/received
    EC3 = Table.AddColumn(EC3c, "_isJS", each
        let childSU = Text.Upper(Text.Trim(
                if [TrackingStatusName] <> null then [TrackingStatusName] else "")),
            taSU    = Text.Upper(Text.Trim(
                if [_taStatus] <> null then [_taStatus] else ""))
        in  List.Contains(_JS_UPPER, childSU)
            or List.Contains(_JS_UPPER, taSU)),

    // Determine display parent: use facility, fallback to TopArea location
    EC4 = Table.AddColumn(EC3, "EffectiveDisplayParentName", each
        if [_isJS]                  then _JS_NAME
        else if [ECTopArea] <> null then _FacilityName([ECTopArea], [_taLocation])
        else                             _FacilityFromLocation([location])),

    EC7 = Table.AddColumn(EC4, "EffectiveDisplayParentId", each
        _FacilityId([EffectiveDisplayParentName], [_taId])),

    // Join container creation date
    EC8 = Table.NestedJoin(EC7, {"id"}, _ContainerDatesR, {"cId"},
              "_cd", JoinKind.LeftOuter),
    EC9 = Table.ExpandTableColumn(EC8, "_cd",
        {"ContainerCreatedDT"}, {"ContainerCreatedDT"}),

    // Join last tracking status change date
    EC10 = Table.NestedJoin(EC9, {"id"}, _CTU_Grouped, {"ContainerId"},
               "_tu", JoinKind.LeftOuter),
    EC11 = Table.ExpandTableColumn(EC10, "_tu",
        {"LastStatusChangeDT"}, {"LastStatusChangeDT"}),

    ChildNoPackageRecords = List.Transform(
        Table.ToRecords(EC11),
        each let
            hasStatus = [TrackingStatusName] <> null,
            refDate   = if hasStatus and [LastStatusChangeDT] <> null
                        then [LastStatusChangeDT]
                        else [ContainerCreatedDT],
            days      = if refDate <> null
                        then Number.Round(
                            Duration.TotalDays(DateTime.LocalNow() - refDate))
                        else null,
            dLabel    = if not hasStatus then
                            if days <> null
                            then Text.From(days) & " days since creation"
                            else "Creation date unknown"
                        else if days <> null
                            then Text.From(days) & " days in current status"
                        else "Duration unknown"
        in [
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
                else _FacilityFromLocation([location]) & " fallback",
            DisplayStatus =
                if hasStatus then [TrackingStatusName]
                else _NOT_USED,
            DisplayState = dLabel,
            DurationDays = days
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
        each let
            isJS = List.Contains(_JS_UPPER,
                Text.Upper(Text.Trim(
                    if [TrackingStatusName] <> null
                    then [TrackingStatusName] else ""))),
            fac  = if isJS then _JS_NAME
                   else _FacilityName([name], [location])
        in not List.Contains(UsedParents, fac)),

    // Join parent creation date
    EP1 = Table.NestedJoin(EmptyParents, {"id"}, _ContainerDatesR, {"cId"},
              "_cd", JoinKind.LeftOuter),
    EP2 = Table.ExpandTableColumn(EP1, "_cd",
        {"ContainerCreatedDT"}, {"ParentCreatedDT"}),

    // Join latest child creation date
    EP3 = Table.NestedJoin(EP2, {"id"}, _LatestChildCreated,
              {"parentContainerId"}, "_lc", JoinKind.LeftOuter),
    EP4 = Table.ExpandTableColumn(EP3, "_lc",
        {"LatestChildCreatedDT"}, {"LatestChildCreatedDT"}),

    ParentEmptyRecords = List.Transform(
        Table.ToRecords(EP4),
        each let
            hasStatus = [TrackingStatusName] <> null,
            isJS      = List.Contains(_JS_UPPER,
                            Text.Upper(Text.Trim(
                                if [TrackingStatusName] <> null
                                then [TrackingStatusName] else ""))),
            facName   = if isJS then _JS_NAME
                        else _FacilityName([name], [location]),
            refDate   = if [LatestChildCreatedDT] <> null
                        then [LatestChildCreatedDT]
                        else [ParentCreatedDT],
            days      = if refDate <> null
                        then Number.Round(
                            Duration.TotalDays(DateTime.LocalNow() - refDate))
                        else null,
            dLabel    = if [LatestChildCreatedDT] <> null then
                            Text.From(days) & " days since last child added"
                        else if not hasStatus then
                            if days <> null
                            then Text.From(days) & " days since creation"
                            else "Creation date unknown"
                        else if days <> null
                            then Text.From(days) & " days since creation"
                        else "Duration unknown"
        in [
            EffectiveDisplayParentId = _FacilityId(facName, [id]),
            EffectiveDisplayParentName = facName,
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
            RelationshipStatus =
                if isJS then "Status override: Job Site"
                else "Empty parent",
            DisplayStatus =
                if hasStatus then [TrackingStatusName]
                else _NOT_USED,
            DisplayState = dLabel,
            DurationDays = days
        ]),
    ParentEmptyTable = Table.FromRecords(ParentEmptyRecords),

    // ─── 14. Union all rows ─────────────────────────────────────────
    AllRows = Table.Combine({
        PkgRowsRenamed,
        UncontainedTable,
        ChildNoPackageTable,
        ParentEmptyTable
    }),

    // ─── 14b. Add duration to package & uncontained rows ────────────
    //  ChildNoPackage and ParentEmpty already carry DurationDays &
    //  DisplayState from their record construction.  For PkgRows and
    //  UncontainedTable those columns are null after Table.Combine.
    //  Enrich: for package rows compute duration based on the owning
    //  container (child if ChildPackage, parent if ParentDirectPackage).
    DR1 = Table.AddColumn(AllRows, "_durContId", each
        if [RowKind] = "ChildPackage"          then [ChildContainerId]
        else if [RowKind] = "ParentDirectPackage" then [ParentContainerId]
        else null),

    // Container creation date
    DR2 = Table.NestedJoin(DR1, {"_durContId"}, _ContainerDatesR, {"cId"},
              "_cd2", JoinKind.LeftOuter),
    DR3 = Table.ExpandTableColumn(DR2, "_cd2",
        {"ContainerCreatedDT"}, {"_cCreated"}),

    // Latest status change
    DR4 = Table.NestedJoin(DR3, {"_durContId"}, _CTU_Grouped, {"ContainerId"},
              "_tu2", JoinKind.LeftOuter),
    DR5 = Table.ExpandTableColumn(DR4, "_tu2",
        {"LastStatusChangeDT"}, {"_cLastStatus"}),

    // Fill DurationDays for rows that don't yet have a value
    DR6 = Table.ReplaceValue(DR5,
        each [DurationDays],
        each if [DurationDays] <> null then [DurationDays]
             else if [_durContId] = null then null
             else let
                 ref = if [_cLastStatus] <> null then [_cLastStatus]
                       else [_cCreated]
             in if ref <> null
                then Number.Round(Duration.TotalDays(DateTime.LocalNow() - ref))
                else null,
        Replacer.ReplaceValue, {"DurationDays"}),

    // Fill DisplayState for rows that don't yet have a value
    DR7 = Table.ReplaceValue(DR6,
        each [DisplayState],
        each if [DisplayState] <> null then [DisplayState]
             else if [_durContId] = null then null
             else let
                 hasStatus = [_cLastStatus] <> null,
                 ref = if hasStatus then [_cLastStatus] else [_cCreated],
                 days = if ref <> null
                        then Number.Round(
                            Duration.TotalDays(DateTime.LocalNow() - ref))
                        else null
             in if days <> null then
                    (if hasStatus
                     then Text.From(days) & " days in current status"
                     else Text.From(days) & " days since creation")
                else null,
        Replacer.ReplaceValue, {"DisplayState"}),

    // Clean up temp columns
    DR8 = Table.RemoveColumns(DR7,
        {"_durContId", "_cCreated", "_cLastStatus"}),

    // ─── 15. Enrich with QR codes ───────────────────────────────────
    // Parent container QR
    QR1 = Table.NestedJoin(DR8, {"ParentContainerName"},
              ContainerQrLookup, {"name"}, "_pqr", JoinKind.LeftOuter),
    QR2 = Table.ExpandTableColumn(QR1, "_pqr",
              {"qrCodeUrl"}, {"ParentContainerQrCode"}),

    // Child container QR
    QR3 = Table.NestedJoin(QR2, {"ChildContainerName"},
              ContainerQrLookup, {"name"}, "_cqr", JoinKind.LeftOuter),
    QR4 = Table.ExpandTableColumn(QR3, "_cqr",
              {"qrCodeUrl"}, {"ChildContainerQrCode"}),

    // Package QR
    QR5 = Table.NestedJoin(QR4, {"PackageName"},
              PackageQrLookup, {"name"}, "_pkqr", JoinKind.LeftOuter),
    QR6 = Table.ExpandTableColumn(QR5, "_pkqr",
              {"qrCodeUrl"}, {"PackageQrCode"}),

    // ─── 16. Final typing ───────────────────────────────────────────
    Typed = Table.TransformColumnTypes(QR6, {
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
        {"DisplayState",               type nullable text},
        {"DurationDays",               type nullable number},
        {"ParentContainerQrCode",      type nullable text},
        {"ChildContainerQrCode",       type nullable text},
        {"PackageQrCode",              type nullable text}
    })
in
    Typed
