*&---------------------------------------------------------------------*
*&  Include           ZABAPGIT_FILE_STATUS
*&---------------------------------------------------------------------*

*----------------------------------------------------------------------*
*       CLASS lcl_file_status DEFINITION
*----------------------------------------------------------------------*
CLASS ltcl_file_status DEFINITION DEFERRED.

CLASS lcl_file_status DEFINITION FINAL
  FRIENDS ltcl_file_status.

  PUBLIC SECTION.

    CLASS-METHODS status
      IMPORTING io_repo           TYPE REF TO lcl_repo
                io_log            TYPE REF TO lcl_log OPTIONAL
      RETURNING VALUE(rt_results) TYPE ty_results_tt
      RAISING   lcx_exception.

  PRIVATE SECTION.

    CLASS-METHODS compare_files
      IMPORTING it_repo         TYPE ty_files_tt
                is_file         TYPE ty_file
      RETURNING VALUE(rv_match) TYPE sap_bool.

    CLASS-METHODS calculate_status_old
      IMPORTING it_local           TYPE ty_files_item_tt
                it_remote          TYPE ty_files_tt
                it_tadir           TYPE ty_tadir_tt
                iv_starting_folder TYPE string
      RETURNING VALUE(rt_results)  TYPE ty_results_tt.

    CLASS-METHODS calculate_status_new
      IMPORTING it_local           TYPE ty_files_item_tt
                it_remote          TYPE ty_files_tt
                it_cur_state       TYPE ty_file_signatures_tt
      RETURNING VALUE(rt_results)  TYPE ty_results_tt.

    CLASS-METHODS:
      build_existing
        IMPORTING is_local         TYPE ty_file_item
                  is_remote        TYPE ty_file
                  it_state         TYPE ty_file_signatures_ts
        RETURNING VALUE(rs_result) TYPE ty_result,
      build_new_local
        IMPORTING is_local         TYPE ty_file_item
        RETURNING VALUE(rs_result) TYPE ty_result,
      build_new_remote
        IMPORTING is_remote        TYPE ty_file
                  it_items         TYPE ty_items_ts
                  it_state         TYPE ty_file_signatures_ts
        RETURNING VALUE(rs_result) TYPE ty_result,
      identify_object
        IMPORTING iv_filename      TYPE string
        EXPORTING es_item          TYPE ty_item
                  ev_is_xml        TYPE abap_bool.

ENDCLASS.                    "lcl_file_status DEFINITION

*----------------------------------------------------------------------*
*       CLASS lcl_file_status IMPLEMENTATION
*----------------------------------------------------------------------*
CLASS lcl_file_status IMPLEMENTATION.

  METHOD compare_files.

    READ TABLE it_repo WITH KEY
      path     = is_file-path
      filename = is_file-filename
      sha1     = is_file-sha1
      TRANSPORTING NO FIELDS.

    rv_match = boolc( sy-subrc = 0 ).

  ENDMETHOD.                    "compare_files

  METHOD status.

    DATA: lv_index       LIKE sy-tabix,
          lo_dot_abapgit TYPE REF TO lcl_dot_abapgit.

    FIELD-SYMBOLS <ls_result> LIKE LINE OF rt_results.

    lo_dot_abapgit = io_repo->get_dot_abapgit( ).

*    rt_results = calculate_status_old(
*      it_local           = io_repo->get_files_local( io_log )
*      it_remote          = io_repo->get_files_remote( )
*      it_tadir           = lcl_tadir=>read( io_repo->get_package( ) )
*      iv_starting_folder = lo_dot_abapgit->get_starting_folder( ) ).

    rt_results = calculate_status_new(
      it_local           = io_repo->get_files_local( io_log )
      it_remote          = io_repo->get_files_remote( )
      it_cur_state       = io_repo->get_local_checksums_per_file( ) ).

    " Remove ignored files, fix .abapgit
    LOOP AT rt_results ASSIGNING <ls_result>.
      lv_index = sy-tabix.

      " Crutch for .abapgit -> it is always match as generated dynamically
      " However this is probably the place to compare it when .abapgit editing
      " tool will be implemented
      IF <ls_result>-path = gc_root_dir AND <ls_result>-filename = gc_dot_abapgit.
        <ls_result>-match = abap_true.
        CLEAR: <ls_result>-lstate, <ls_result>-rstate.
        CONTINUE.
      ENDIF.

      IF lo_dot_abapgit->is_ignored(
          iv_path     = <ls_result>-path
          iv_filename = <ls_result>-filename ) = abap_true.
        DELETE rt_results INDEX lv_index.
      ENDIF.
    ENDLOOP.

    lcl_sap_package=>check(
      io_log     = io_log
      it_results = rt_results
      iv_start   = lo_dot_abapgit->get_starting_folder( )
      iv_top     = io_repo->get_package( ) ).

  ENDMETHOD.  "status

  METHOD calculate_status_new.

    DATA: lt_remote    LIKE it_remote,
          lt_items     TYPE ty_items_tt,
          ls_item      LIKE LINE OF lt_items,
          lv_is_xml    TYPE abap_bool,
          lt_items_idx TYPE ty_items_ts,
          lt_state_idx TYPE ty_file_signatures_ts. " Sorted by path+filename

    FIELD-SYMBOLS: <ls_remote> LIKE LINE OF it_remote,
                   <ls_result> LIKE LINE OF rt_results,
                   <ls_local>  LIKE LINE OF it_local.

    lt_state_idx = it_cur_state. " Force sort it
    lt_remote    = it_remote.
    SORT lt_remote BY path filename.

    " Process local files and new local files
    LOOP AT it_local ASSIGNING <ls_local>.
      APPEND INITIAL LINE TO rt_results ASSIGNING <ls_result>.
      APPEND <ls_local>-item TO lt_items. " Collect for item index

      READ TABLE lt_remote ASSIGNING <ls_remote>
        WITH KEY path = <ls_local>-file-path filename = <ls_local>-file-filename
        BINARY SEARCH.
      IF sy-subrc = 0.  " Exist L and R
        <ls_result> = build_existing(
          is_local  = <ls_local>
          is_remote = <ls_remote>
          it_state  = lt_state_idx ).
        ASSERT <ls_remote>-sha1 IS NOT INITIAL.
        CLEAR <ls_remote>-sha1. " Mark as processed
      ELSE.             " Only L exists
        <ls_result> = build_new_local( is_local = <ls_local> ).
      ENDIF.
    ENDLOOP.

    " Complete item index for unmarked remote files
    LOOP AT lt_remote ASSIGNING <ls_remote> WHERE sha1 IS NOT INITIAL.
      identify_object( EXPORTING iv_filename = <ls_remote>-filename
                       IMPORTING es_item     = ls_item
                                 ev_is_xml   = lv_is_xml ).

      CHECK lv_is_xml = abap_true. " Skip all but obj definitions

      ls_item-devclass = lcl_tadir=>get_object_package(
                           iv_object   = ls_item-obj_type
                           iv_obj_name = ls_item-obj_name ).
      APPEND ls_item TO lt_items.
    ENDLOOP.

    SORT lt_items. " Default key - type, name, pkg
    DELETE ADJACENT DUPLICATES FROM lt_items.
    lt_items_idx = lt_items. " Self protection + UNIQUE records assertion

    " Process new remote files (marked above with empty SHA1)
    LOOP AT lt_remote ASSIGNING <ls_remote> WHERE sha1 IS NOT INITIAL.
      APPEND INITIAL LINE TO rt_results ASSIGNING <ls_result>.
      <ls_result> = build_new_remote( is_remote = <ls_remote>
                                      it_items  = lt_items_idx
                                      it_state  = lt_state_idx ).
    ENDLOOP.

    SORT rt_results BY
      obj_type ASCENDING
      obj_name ASCENDING
      filename ASCENDING.

  ENDMETHOD.  "calculate_status_new.

  METHOD identify_object.

    DATA: lv_name   TYPE tadir-obj_name,
          lv_type   TYPE string,
          lv_ext    TYPE string.

    " Guess object type and name
    SPLIT to_upper( iv_filename ) AT '.' INTO lv_name lv_type lv_ext.

    " Handle namespaces
    REPLACE ALL OCCURRENCES OF '#' IN lv_name WITH '/'.

    CLEAR es_item.
    es_item-obj_type = lv_type.
    es_item-obj_name = lv_name.
    ev_is_xml        = boolc( lv_ext = 'XML' AND strlen( lv_type ) = 4 ).

  ENDMETHOD.  "identify_object.

  METHOD build_existing.

    DATA: ls_file_sig LIKE LINE OF it_state.

    " Item
    rs_result-obj_type = is_local-item-obj_type.
    rs_result-obj_name = is_local-item-obj_name.
    rs_result-package  = is_local-item-devclass.

    " File
    rs_result-path     = is_local-file-path.
    rs_result-filename = is_local-file-filename.

    " Match against current state
    READ TABLE it_state INTO ls_file_sig
      WITH KEY path = is_local-file-path filename = is_local-file-filename
      BINARY SEARCH.

    IF sy-subrc = 0.
      IF ls_file_sig-sha1 <> is_local-file-sha1.
        rs_result-lstate = gc_state-modified.
      ENDIF.
      IF ls_file_sig-sha1 <> is_remote-sha1.
        rs_result-rstate = gc_state-modified.
      ENDIF.
      rs_result-match = boolc( rs_result-lstate IS INITIAL AND rs_result-rstate IS INITIAL ).
    ELSE.
      " This is a strange situation. As both local and remote exist
      " the state should also be present. Maybe this is a first run of the code.
      " In this case just compare hashes directly and mark both changed
      " the user will presumably decide what to do after checking the actual diff
      rs_result-match = boolc( is_local-file-sha1 = is_remote-sha1 ).
      IF rs_result-match = abap_false.
        rs_result-lstate = gc_state-modified.
        rs_result-rstate = gc_state-modified.
      ENDIF.
    ENDIF.

  ENDMETHOD.  "build_existing

  METHOD build_new_local.

    " Item
    rs_result-obj_type = is_local-item-obj_type.
    rs_result-obj_name = is_local-item-obj_name.
    rs_result-package  = is_local-item-devclass.

    " File
    rs_result-path     = is_local-file-path.
    rs_result-filename = is_local-file-filename.

    " Match
    rs_result-match    = abap_false.
    rs_result-lstate   = gc_state-added.

  ENDMETHOD.  "build_new_local

  METHOD build_new_remote.

    DATA: ls_item     LIKE LINE OF it_items,
          ls_file_sig LIKE LINE OF it_state.

    " Common and default part
    rs_result-path     = is_remote-path.
    rs_result-filename = is_remote-filename.
    rs_result-match    = abap_false.
    rs_result-rstate   = gc_state-added.

    identify_object( EXPORTING iv_filename = is_remote-filename
                     IMPORTING es_item     = ls_item ).

    " Check if in item index + get package
    READ TABLE it_items INTO ls_item
      WITH KEY obj_type = ls_item-obj_type obj_name = ls_item-obj_name
      BINARY SEARCH.

    IF sy-subrc = 0.

      " Completely new (xml, abap) and new file in an existing object
      rs_result-obj_type = ls_item-obj_type.
      rs_result-obj_name = ls_item-obj_name.
      rs_result-package  = ls_item-devclass.

      READ TABLE it_state INTO ls_file_sig
        WITH KEY path = is_remote-path filename = is_remote-filename
        BINARY SEARCH.

      " Existing file but from another package
      " was not added during local file proc as was not in tadir for repo package
      IF sy-subrc = 0.
        IF ls_file_sig-sha1 = is_remote-sha1.
          rs_result-match  = abap_true.
          CLEAR rs_result-rstate.
        ELSE.
          rs_result-rstate = gc_state-modified.
        ENDIF.
      ENDIF.

    ELSE. " Completely unknown file, probably non-abapgit
      " No action, just follow defaults
      ASSERT 1 = 1.
    ENDIF.

  ENDMETHOD.  "build_new_remote

  METHOD calculate_status_old.

    DATA: lv_pre    TYPE tadir-obj_name,
          lt_files  TYPE ty_files_tt,
          ls_result LIKE LINE OF rt_results,
          lv_type   TYPE string,
          ls_item   TYPE ty_item,
          ls_tadir  TYPE tadir,
          lv_ext    TYPE string.

    FIELD-SYMBOLS: <ls_remote> LIKE LINE OF it_remote,
                   <ls_tadir>  LIKE LINE OF it_tadir,
                   <ls_result> LIKE LINE OF rt_results,
                   <ls_local>  LIKE LINE OF it_local,
                   <ls_file>   LIKE LINE OF lt_files.


    LOOP AT it_remote ASSIGNING <ls_remote>.

      " Guess object type and name
      SPLIT <ls_remote>-filename AT '.' INTO lv_pre lv_type lv_ext.
      TRANSLATE lv_pre TO UPPER CASE.
      TRANSLATE lv_type TO UPPER CASE.

      IF lv_ext <> 'xml' OR strlen( lv_type ) <> 4.
        CONTINUE. " current loop
      ENDIF.

      " handle namespaces
      REPLACE ALL OCCURRENCES OF '#' IN lv_pre WITH '/'.

      CLEAR ls_result.
      ls_result-obj_type = lv_type.
      ls_result-obj_name = lv_pre.

      CLEAR ls_item.
      ls_item-obj_type = lv_type.
      ls_item-obj_name = lv_pre.

      " Add corresponding local files
      CLEAR lt_files.
      LOOP AT it_local ASSIGNING <ls_local>
        WHERE item-obj_type = ls_item-obj_type AND item-obj_name = ls_item-obj_name.
        APPEND <ls_local>-file TO lt_files.
      ENDLOOP.

      " item does not exist locally
      IF lt_files[] IS INITIAL.
        ls_result-filename = <ls_remote>-filename.
        ls_result-rstate   = gc_state-added.
        APPEND ls_result TO rt_results.
        CONTINUE. " current loop
      ENDIF.

      LOOP AT lt_files ASSIGNING <ls_file>.
        ls_result-filename = <ls_file>-filename.
        ls_result-match    = compare_files( it_repo = it_remote
                                            is_file = <ls_file> ).
        APPEND ls_result TO rt_results.
      ENDLOOP.
    ENDLOOP.

* find files only existing remotely, including non abapGit related
    LOOP AT it_remote ASSIGNING <ls_remote>.
      READ TABLE rt_results WITH KEY filename = <ls_remote>-filename
        TRANSPORTING NO FIELDS.
      IF sy-subrc <> 0.
        CLEAR ls_result.
        ls_result-match    = abap_false.
        ls_result-rstate   = gc_state-added.
        ls_result-filename = <ls_remote>-filename.
        APPEND ls_result TO rt_results.
      ENDIF.
    ENDLOOP.

* add path information for files
    LOOP AT it_remote ASSIGNING <ls_remote>.
      READ TABLE rt_results ASSIGNING <ls_result> WITH KEY filename = <ls_remote>-filename.
      IF sy-subrc = 0.
        <ls_result>-path = <ls_remote>-path.
      ENDIF.
    ENDLOOP.

* find objects only existing locally
    LOOP AT it_tadir ASSIGNING <ls_tadir>.
      READ TABLE rt_results
        WITH KEY obj_type = <ls_tadir>-object
                 obj_name = <ls_tadir>-obj_name
        TRANSPORTING NO FIELDS.
      IF sy-subrc <> 0.
        ls_item-obj_type = <ls_tadir>-object.
        ls_item-obj_name = <ls_tadir>-obj_name.
        IF lcl_objects=>is_supported( ls_item ) = abap_false.
          CONTINUE.
        ENDIF.

        CLEAR ls_result.
        ls_result-match    = abap_false.
        ls_result-obj_type = <ls_tadir>-object.
        ls_result-obj_name = <ls_tadir>-obj_name.
        ls_result-lstate   = gc_state-added.
        APPEND ls_result TO rt_results.
      ENDIF.

      LOOP AT rt_results ASSIGNING <ls_result>
          WHERE obj_type = <ls_tadir>-object
          AND   obj_name = <ls_tadir>-obj_name
          AND   path IS INITIAL.
* new file added locally to existing object
        <ls_result>-path   = iv_starting_folder && <ls_tadir>-path.
        <ls_result>-lstate = gc_state-added.
      ENDLOOP.
    ENDLOOP.

* add package information
    LOOP AT rt_results ASSIGNING <ls_result> WHERE NOT obj_type IS INITIAL.
      CLEAR ls_tadir.
      READ TABLE it_tadir ASSIGNING <ls_tadir>
        WITH KEY object = <ls_result>-obj_type obj_name = <ls_result>-obj_name.
      IF sy-subrc > 0. " Not found -> Another package ?
        ls_tadir = lcl_tadir=>read_single( iv_object   = <ls_result>-obj_type
                                           iv_obj_name = <ls_result>-obj_name ).
        <ls_result>-package = ls_tadir-devclass.
      ELSE.
        <ls_result>-package = <ls_tadir>-devclass.
      ENDIF.
    ENDLOOP.

    SORT rt_results BY
      obj_type ASCENDING
      obj_name ASCENDING
      filename ASCENDING.
    DELETE ADJACENT DUPLICATES FROM rt_results
      COMPARING obj_type obj_name filename.

  ENDMETHOD.                    "calculate_status_old

ENDCLASS.                    "lcl_file_status IMPLEMENTATION