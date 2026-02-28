// =====================================================================
//  Container + Package Display Hierarchy
//  ─────────────────────────────────────
//  Paste this into Power BI → Home → Transform Data → New Query →
//  Advanced Editor.
//
//  Produces a FLAT display table for a Matrix or Table visual:
//    EffectiveDisplayParent ▸ AreaRow ▸ Rack ▸ Shelf ▸
//    ChildContainer ▸ Package
//
//  References existing model tables:  Containers, Packages
// =====================================================================
let
    // ─── Configuration ──────────────────────────────────────────────
    _JS_NAME        = "Job Site",
    _JS_ID          = "SYN-JOBSITE",
    _WH_NAME        = "180 Campanelli IR 6 Ericsson",
    _WH_ID          = "SYN-WAREHOUSE",
    _NO_PARENT      = "(No Parent Container)",
    _NO_CHILD_CTR   = "(No Child Container)",
    _NO_CONTAINER   = "(No Container)",
    _NO_PKG         = "(No Package)",
    _DIRECT         = "(Directly on Parent)",
    _JS_UPPER       = {"SHIPPED TO JOBSITE", "RECEIVED ON JOBSITE"},
    _USE_WH         = true,                     // warehouse fallback ON
    _CHILD_TYPES    = {"Cart","Pallet","Shipping","Basket","Box"},

    // ─── A.  Classify every container ───────────────────────────────
    //  Role: TopArea | AreaRow | Rack | Shelf | Child
    A_Tagged = Table.AddColumn(
        Containers,
        "Role",
        each
            if List.Contains(_CHILD_TYPES, [#"Group Type"])        then "Child"
            else if [#"Group Type"] = "Shelf"                      then "Shelf"
            else if [#"Group Type"] = "Rack"                       then "Rack"
            else if [Type] = "Area"
                    and Text.Contains([Name], "ROW",
                            Comparer.OrdinalIgnoreCase)            then "AreaRow"
            else                                                        "TopArea"
    ),

    A_All = Table.Buffer(
        Table.SelectColumns(A_Tagged,
            {"Name","Id","Type","Status","State",
             "Description","Group Type","Role"})),

    A_TopAreas  = Table.Buffer(Table.SelectRows(A_All, each [Role] = "TopArea")),
    A_AreaRows  = Table.Buffer(Table.SelectRows(A_All, each [Role] = "AreaRow")),
    A_Racks     = Table.Buffer(Table.SelectRows(A_All, each [Role] = "Rack")),
    A_Shelves   = Table.Buffer(Table.SelectRows(A_All, each [Role] = "Shelf")),
    A_Children  = Table.Buffer(Table.SelectRows(A_All, each [Role] = "Child")),

    A_RackNames    = List.Buffer(Table.Column(A_Racks, "Name")),
    A_AreaRowNames = List.Buffer(Table.Column(A_AreaRows, "Name")),

    // Main prefab area (the "Prefab Area" that is NOT an AreaRow)
    _PrefabAreas = Table.SelectRows(A_TopAreas,
        each [#"Group Type"] = "Prefab Area"),
    _MainPrefab  = if Table.RowCount(_PrefabAreas) > 0
                   then _PrefabAreas{0}[Name] else null,

    // ─── B.  Prefab naming-rule maps ────────────────────────────────
    //  Shelf → Rack  (shelf name starts with rack name; longest match)
    B_S2R = Table.Buffer(
        Table.SelectColumns(
            Table.AddColumn(A_Shelves, "_RackName", each
                let hits = List.Select(A_RackNames, (rn) =>
                        Text.StartsWith([Name], rn,
                            Comparer.OrdinalIgnoreCase)),
                    best = if List.Count(hits) = 0 then null
                           else List.Last(List.Sort(hits, (a,b) =>
                               Value.Compare(Text.Length(a),
                                             Text.Length(b))))
                in best),
            {"Name","_RackName"})),

    //  Rack → AreaRow  (first letter ↔ "ROW <letter>")
    B_R2AR = Table.Buffer(
        Table.SelectColumns(
            Table.AddColumn(A_Racks, "_AreaRowName", each
                let letter = Text.Upper(Text.Start([Name], 1)),
                    hits   = List.Select(A_AreaRowNames, (ar) =>
                        Text.Contains(ar, "ROW " & letter,
                            Comparer.OrdinalIgnoreCase))
                in if List.Count(hits) > 0 then hits{0} else null),
            {"Name","_AreaRowName"})),

    // ─── C.  Universal container chain ──────────────────────────────
    //  Every container → (ChainTopArea, ChainAreaRow, ChainRack, ChainShelf)
    C1 = Table.NestedJoin(A_All, {"Name"}, B_S2R, {"Name"},
             "_s", JoinKind.LeftOuter),
    C2 = Table.ExpandTableColumn(C1,
             "_s", {"_RackName"}, {"_mRack"}),

    // Effective rack
    C3 = Table.AddColumn(C2, "_eRack", each
        if [Role] = "Rack" then [Name] else [_mRack]),

    C4 = Table.NestedJoin(C3, {"_eRack"}, B_R2AR, {"Name"},
             "_r", JoinKind.LeftOuter),
    C5 = Table.ExpandTableColumn(C4,
             "_r", {"_AreaRowName"}, {"_mAreaRow"}),

    // Effective area row
    C6 = Table.AddColumn(C5, "_eAreaRow", each
        if [Role] = "AreaRow" then [Name] else [_mAreaRow]),

    // Effective top area
    C7 = Table.AddColumn(C6, "_eTopArea", each
        if [Role] = "TopArea"         then [Name]
        else if [_eAreaRow] <> null   then _MainPrefab
        else null),

    // Effective shelf
    C8 = Table.AddColumn(C7, "_eShelf", each
        if [Role] = "Shelf" then [Name] else null),

    Chain = Table.Buffer(
        Table.RenameColumns(
            Table.SelectColumns(C8,
                {"Name","Id","Role","Status","State","Type",
                 "Group Type","_eTopArea","_eAreaRow","_eRack","_eShelf"}),
            {{"_eTopArea","ChainTopArea"},{"_eAreaRow","ChainAreaRow"},
             {"_eRack","ChainRack"},{"_eShelf","ChainShelf"}})),

    // ─── D.  Package → container resolution ─────────────────────────
    D_Src = Table.RenameColumns(
        Table.SelectColumns(Packages,
            {"Name","Id","Status_",
             "PackageContainer.1","PackageContainer.2"}),
        {{"Name","PkgName"},{"Id","PkgId"},{"Status_","PkgStatus"}}),

    // Clean PC.2 (trim / clean / upper – matches existing Merge1 logic)
    D_Clean = Table.TransformColumns(D_Src,
        {{"PackageContainer.2", each
              if _ = null then null
              else Text.Upper(Text.Trim(Text.Clean(_))),
              type nullable text}}),

    // Join PC.1 → Chain
    D1 = Table.NestedJoin(D_Clean, {"PackageContainer.1"}, Chain, {"Name"},
             "_j1", JoinKind.LeftOuter),
    D2 = Table.ExpandTableColumn(D1, "_j1",
        {"Role","Id","Type","ChainTopArea","ChainAreaRow",
         "ChainRack","ChainShelf","Status","State"},
        {"PC1Role","PC1CId","PC1CType","PC1TopArea","PC1AreaRow",
         "PC1Rack","PC1Shelf","PC1CStatus","PC1CState"}),

    // Join PC.2 → Chain
    D3 = Table.NestedJoin(D2, {"PackageContainer.2"}, Chain, {"Name"},
             "_j2", JoinKind.LeftOuter),
    D4 = Table.ExpandTableColumn(D3, "_j2",
        {"Role","Id","Type","ChainTopArea","ChainAreaRow",
         "ChainRack","ChainShelf","Status","State"},
        {"PC2Role","PC2CId","PC2CType","PC2TopArea","PC2AreaRow",
         "PC2Rack","PC2Shelf","PC2CStatus","PC2CState"}),

    // Resolve which is the "parent-class" container (TopArea/AreaRow/
    // Rack/Shelf) and which is the "child" container
    D5 = Table.AddColumn(D4, "_pName", each
        if [PC1Role] <> null and [PC1Role] <> "Child"
            then [#"PackageContainer.1"]
        else if [PC2Role] <> null and [PC2Role] <> "Child"
            then [#"PackageContainer.2"]
        else null),

    D6 = Table.AddColumn(D5, "_pId", each
        if [PC1Role] <> null and [PC1Role] <> "Child" then [PC1CId]
        else if [PC2Role] <> null and [PC2Role] <> "Child" then [PC2CId]
        else null),

    D7 = Table.AddColumn(D6, "_cName", each
        if [PC1Role] = "Child"  then [#"PackageContainer.1"]
        else if [PC2Role] = "Child" then [#"PackageContainer.2"]
        else null),

    D8 = Table.AddColumn(D7, "_cId", each
        if [PC1Role] = "Child"  then [PC1CId]
        else if [PC2Role] = "Child" then [PC2CId]
        else null),

    D9 = Table.AddColumn(D8, "_cType", each
        if [PC1Role] = "Child"  then [PC1CType]
        else if [PC2Role] = "Child" then [PC2CType]
        else null),

    // Pull hierarchy info from whichever container was the parent-class
    D10 = Table.AddColumn(D9, "_topArea", each
        if [PC1Role] <> null and [PC1Role] <> "Child" then [PC1TopArea]
        else if [PC2Role] <> null and [PC2Role] <> "Child" then [PC2TopArea]
        else null),

    D11 = Table.AddColumn(D10, "_areaRow", each
        if [PC1Role] <> null and [PC1Role] <> "Child" then [PC1AreaRow]
        else if [PC2Role] <> null and [PC2Role] <> "Child" then [PC2AreaRow]
        else null),

    D12 = Table.AddColumn(D11, "_rack", each
        if [PC1Role] <> null and [PC1Role] <> "Child" then [PC1Rack]
        else if [PC2Role] <> null and [PC2Role] <> "Child" then [PC2Rack]
        else null),

    D13 = Table.AddColumn(D12, "_shelf", each
        if [PC1Role] <> null and [PC1Role] <> "Child" then [PC1Shelf]
        else if [PC2Role] <> null and [PC2Role] <> "Child" then [PC2Shelf]
        else null),

    // Status fields for override checks
    D14 = Table.AddColumn(D13, "_cStatus", each
        if [PC1Role] = "Child" then [PC1CStatus]
        else if [PC2Role] = "Child" then [PC2CStatus]
        else null),

    D15 = Table.AddColumn(D14, "_cState", each
        if [PC1Role] = "Child" then [PC1CState]
        else if [PC2Role] = "Child" then [PC2CState]
        else null),

    D_Resolved = Table.Buffer(
        Table.SelectColumns(D15,
            {"PkgName","PkgId","PkgStatus",
             "_pName","_pId","_topArea","_areaRow","_rack","_shelf",
             "_cName","_cId","_cType","_cStatus","_cState"})),

    // ─── E.  Child → parent inference (package overlap) ─────────────
    //  For children whose packages lack a direct parent, infer one from
    //  OTHER packages in the same child that DO have an assigned parent.
    E_HasBoth = Table.SelectRows(D_Resolved,
        each [_pName] <> null and [_cName] <> null),
    E_Pairs = Table.Distinct(
        Table.SelectColumns(E_HasBoth,
            {"_cName","_pName","_pId",
             "_topArea","_areaRow","_rack","_shelf"})),

    // Group by child – keep only children with exactly 1 distinct parent
    E_Grouped = Table.Group(E_Pairs, {"_cName"}, {
        {"_tbl", each _, type table},
        {"_cnt", each List.Count(List.Distinct([_pName])), Int64.Type}}),
    E_Single = Table.SelectRows(E_Grouped, each [_cnt] = 1),

    // Expand the single parent record per child
    E_Flat = Table.AddColumn(E_Single, "_r", each [_tbl]{0}),
    E_Exp  = Table.ExpandRecordColumn(
        Table.SelectColumns(E_Flat, {"_cName","_r"}),
        "_r",
        {"_pName","_pId","_topArea","_areaRow","_rack","_shelf"},
        {"InfPName","InfPId","InfTopArea","InfAreaRow","InfRack","InfShelf"}),
    E_Infer = Table.Buffer(E_Exp),

    // ─── F.  Merge inferred parents into package data ───────────────
    F1 = Table.NestedJoin(D_Resolved, {"_cName"}, E_Infer, {"_cName"},
             "_inf", JoinKind.LeftOuter),
    F2 = Table.ExpandTableColumn(F1, "_inf",
        {"InfPName","InfPId","InfTopArea","InfAreaRow","InfRack","InfShelf"}),

    // Pick best-available values: direct > inferred
    F3 = Table.AddColumn(F2, "ParentContainerName", each
        if [_pName] <> null then [_pName] else [InfPName]),
    F4 = Table.AddColumn(F3, "ParentContainerId", each
        if [_pId] <> null then [_pId] else [InfPId]),
    F5 = Table.AddColumn(F4, "TopAreaName", each
        if [_topArea] <> null then [_topArea] else [InfTopArea]),
    F6 = Table.AddColumn(F5, "AreaRowName", each
        if [_areaRow] <> null then [_areaRow] else [InfAreaRow]),
    F7 = Table.AddColumn(F6, "RackName", each
        if [_rack] <> null then [_rack] else [InfRack]),
    F8 = Table.AddColumn(F7, "ShelfName", each
        if [_shelf] <> null then [_shelf] else [InfShelf]),

    // How was the parent resolved?
    F9 = Table.AddColumn(F8, "_howResolved", each
        if [_pName] <> null       then "Direct assignment"
        else if [InfPName] <> null then "Inferred from package overlap"
        else if [_cName] <> null   then "No parent found"
        else                            "No container"),

    // RowKind classification
    F10 = Table.AddColumn(F9, "RowKind", each
        if [_cName] <> null                  then "ChildPackage"
        else if [ParentContainerName] <> null then "ParentDirectPackage"
        else                                      "UncontainedPackage"),

    // ─── G.  EffectiveDisplayParent resolution ──────────────────────
    //  1. Status override → Job Site
    //  2. Resolved TopArea → real parent
    //  3. Warehouse fallback (or no parent)
    G1 = Table.AddColumn(F10, "_pkgSU", each
        Text.Upper(Text.Trim(
            if [PkgStatus] <> null then [PkgStatus] else ""))),
    G2 = Table.AddColumn(G1, "_cSU", each
        Text.Upper(Text.Trim(
            if [_cStatus] <> null then [_cStatus] else ""))),

    G3 = Table.AddColumn(G2, "_isJS", each
        List.Contains(_JS_UPPER, [_pkgSU])
        or List.Contains(_JS_UPPER, [_cSU])),

    G4 = Table.AddColumn(G3, "EffectiveDisplayParentName", each
        if [_isJS]               then _JS_NAME
        else if [TopAreaName] <> null then [TopAreaName]
        else if _USE_WH              then _WH_NAME
        else                              _NO_PARENT),

    // Look up top-area Id via join
    G5 = Table.NestedJoin(G4, {"TopAreaName"}, A_TopAreas, {"Name"},
             "_taJ", JoinKind.LeftOuter),
    G6 = Table.ExpandTableColumn(G5, "_taJ", {"Id"}, {"_taId"}),

    G7 = Table.AddColumn(G6, "EffectiveDisplayParentId", each
        if [EffectiveDisplayParentName] = _JS_NAME then _JS_ID
        else if [EffectiveDisplayParentName] = _WH_NAME then _WH_ID
        else if [EffectiveDisplayParentName] = _NO_PARENT then null
        else [_taId]),

    G8 = Table.AddColumn(G7, "RelationshipStatus", each
        if [_isJS]                     then "Status override: Job Site"
        else if [_howResolved] = "Direct assignment"
                                       then "Direct assignment"
        else if [_howResolved] = "Inferred from package overlap"
                                       then "Inferred from package overlap"
        else if [_howResolved] = "No parent found" and _USE_WH
                                       then "Warehouse fallback"
        else if [_howResolved] = "No parent found"
                                       then "No parent found"
        else                                "No container"),

    // Display columns
    G9 = Table.AddColumn(G8, "ChildContainerName", each
        if [_cName] <> null                        then [_cName]
        else if [RowKind] = "ParentDirectPackage"  then _DIRECT
        else                                            _NO_CONTAINER),

    G10 = Table.AddColumn(G9, "ChildContainerId", each [_cId]),
    G11 = Table.AddColumn(G10, "ChildContainerType", each [_cType]),
    G12 = Table.AddColumn(G11, "PackageName", each [PkgName]),
    G13 = Table.AddColumn(G12, "DisplayStatus", each
        if [_cName] <> null and [_cStatus] <> null
            then [_cStatus]         // child container's tracking status
            else [PkgStatus]),      // package's own status
    G14 = Table.AddColumn(G13, "DisplayState", each [_cState]),

    // Select final columns for package-based rows
    PkgRows = Table.SelectColumns(G14,
        {"EffectiveDisplayParentId","EffectiveDisplayParentName",
         "ParentContainerId","ParentContainerName",
         "AreaRowName","RackName","ShelfName",
         "ChildContainerId","ChildContainerName","ChildContainerType",
         "PackageName","RowKind","RelationshipStatus",
         "DisplayStatus","DisplayState"}),

    // ─── H.  ChildNoPackage rows  (empty child containers) ─────────
    H_UsedChildNames = List.Buffer(List.Distinct(
        List.RemoveNulls(Table.Column(D_Resolved, "_cName")))),

    H_Empty = Table.SelectRows(A_Children,
        each not List.Contains(H_UsedChildNames, [Name])),

    // Resolve parent for empty children via inference map
    H1 = Table.NestedJoin(H_Empty, {"Name"}, E_Infer, {"_cName"},
             "_inf", JoinKind.LeftOuter),
    H2 = Table.ExpandTableColumn(H1, "_inf",
        {"InfPName","InfPId","InfTopArea","InfAreaRow","InfRack","InfShelf"}),

    // Status override check
    H3 = Table.AddColumn(H2, "_isJS", each
        List.Contains(_JS_UPPER,
            Text.Upper(Text.Trim(
                if [Status] <> null then [Status] else "")))),

    // TopArea for display parent
    H4 = Table.AddColumn(H3, "_topArea", each [InfTopArea]),

    // EffectiveDisplayParent
    H5 = Table.AddColumn(H4, "EffectiveDisplayParentName", each
        if [_isJS]              then _JS_NAME
        else if [_topArea] <> null then [_topArea]
        else if _USE_WH             then _WH_NAME
        else                             _NO_PARENT),

    H6 = Table.NestedJoin(H5, {"_topArea"}, A_TopAreas, {"Name"},
             "_taJ", JoinKind.LeftOuter),
    H7 = Table.ExpandTableColumn(H6, "_taJ", {"Id"}, {"_taId"}),

    H8  = Table.AddColumn(H7, "EffectiveDisplayParentId", each
        if [EffectiveDisplayParentName] = _JS_NAME then _JS_ID
        else if [EffectiveDisplayParentName] = _WH_NAME then _WH_ID
        else if [EffectiveDisplayParentName] = _NO_PARENT then null
        else [_taId]),

    H9  = Table.AddColumn(H8, "ParentContainerId", each [InfPId]),
    H10 = Table.AddColumn(H9, "ParentContainerName", each [InfPName]),
    H11 = Table.AddColumn(H10, "AreaRowName", each [InfAreaRow]),
    H12 = Table.AddColumn(H11, "RackName", each [InfRack]),
    H13 = Table.AddColumn(H12, "ShelfName", each [InfShelf]),
    H14 = Table.AddColumn(H13, "ChildContainerId", each [Id]),
    H15 = Table.AddColumn(H14, "ChildContainerName", each [Name]),
    H16 = Table.AddColumn(H15, "ChildContainerType", each [Type]),
    H17 = Table.AddColumn(H16, "PackageName", each _NO_PKG),
    H18 = Table.AddColumn(H17, "RowKind", each "ChildNoPackage"),
    H19 = Table.AddColumn(H18, "RelationshipStatus", each
        if [_isJS]                  then "Status override: Job Site"
        else if [InfPName] <> null  then "Inferred from package overlap"
        else if _USE_WH             then "Warehouse fallback"
        else                             "No parent found"),
    H20 = Table.AddColumn(H19, "DisplayStatus", each [Status]),
    H21 = Table.AddColumn(H20, "DisplayState", each [State]),

    ChildNoPackageRows = Table.SelectColumns(H21,
        {"EffectiveDisplayParentId","EffectiveDisplayParentName",
         "ParentContainerId","ParentContainerName",
         "AreaRowName","RackName","ShelfName",
         "ChildContainerId","ChildContainerName","ChildContainerType",
         "PackageName","RowKind","RelationshipStatus",
         "DisplayStatus","DisplayState"}),

    // ─── I.  ParentEmpty rows  (top-level parents with nothing) ─────
    //  A TopArea that does not appear as EffectiveDisplayParentName in
    //  any package row or ChildNoPackage row.
    I_UsedParents = List.Buffer(List.Distinct(List.Combine({
        Table.Column(PkgRows, "EffectiveDisplayParentName"),
        Table.Column(ChildNoPackageRows, "EffectiveDisplayParentName")
    }))),

    I_EmptyParents = Table.SelectRows(A_TopAreas,
        each not List.Contains(I_UsedParents, [Name])),

    I1  = Table.AddColumn(I_EmptyParents, "EffectiveDisplayParentName",
              each [Name]),
    I2  = Table.AddColumn(I1, "EffectiveDisplayParentId", each [Id]),
    I3  = Table.AddColumn(I2, "ParentContainerId",   each [Id]),
    I4  = Table.AddColumn(I3, "ParentContainerName",  each [Name]),
    I5  = Table.AddColumn(I4, "AreaRowName",          each null as nullable text),
    I6  = Table.AddColumn(I5, "RackName",             each null as nullable text),
    I7  = Table.AddColumn(I6, "ShelfName",            each null as nullable text),
    I8  = Table.AddColumn(I7, "ChildContainerId",     each null as nullable text),
    I9  = Table.AddColumn(I8, "ChildContainerName",   each _NO_CHILD_CTR),
    I10 = Table.AddColumn(I9, "ChildContainerType",   each null as nullable text),
    I11 = Table.AddColumn(I10, "PackageName",          each _NO_PKG),
    I12 = Table.AddColumn(I11, "RowKind",              each "ParentEmpty"),
    I13 = Table.AddColumn(I12, "RelationshipStatus",   each "Empty parent"),
    I14 = Table.AddColumn(I13, "DisplayStatus",        each [Status]),
    I15 = Table.AddColumn(I14, "DisplayState",         each [State]),

    ParentEmptyRows = Table.SelectColumns(I15,
        {"EffectiveDisplayParentId","EffectiveDisplayParentName",
         "ParentContainerId","ParentContainerName",
         "AreaRowName","RackName","ShelfName",
         "ChildContainerId","ChildContainerName","ChildContainerType",
         "PackageName","RowKind","RelationshipStatus",
         "DisplayStatus","DisplayState"}),

    // ─── J.  Union all row types ────────────────────────────────────
    AllRows = Table.Combine({
        PkgRows,
        ChildNoPackageRows,
        ParentEmptyRows
    }),

    // ─── K.  Final typing ───────────────────────────────────────────
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
