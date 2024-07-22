#!/bin/bash
# MODIFIED BY UMAR - 7/16/2024
# This is bash-like pseudo code designed to express the thoughts

set -euo pipefail

SCRIPT_DIRNAME=$(dirname $BASH_SOURCE[0])
SCRIPT_PATH=$(readlink -f $SCRIPT_DIRNAME)

if [ "$#" -lt  "4" ]; then
    echo "Usage: $0 target_schema customer_name project_name config_file"
    exit 1
fi

TARGET_SCHEMA="$1"
CUSTOMER_NAME="$2"
PROJECT_NAME="$3"
CONFIG_FILE="$4"

if [ ! -e "$CONFIG_FILE" ]; then
    echo "QUery file $CONFIG_FILE does not exist"
    exit 1
fi

SQL_DIR="${SCRIPT_PATH}/sql"

if [ ! -e "$SQL_DIR" ]; then
    echo "SQL directory $SQL_DIR does not exist"
    exit 1
fi


QUERY_USER=ughumman
QUERY_USER_PASSWORD='""'

ADMIN_USER=ughumman
ADMIN_PASSWORD=''

VSQL=${VSQL:-vsql}

VSQL_ADMIN_COMMAND="${VSQL} -U $ADMIN_USER -w $ADMIN_PASSWORD " # UMAR TEMP CHANGE => VSQL_ADMIN_COMMAND="${VSQL} -U $ADMIN_USER -w $ADMIN_PASSWORD "
VSQL_USER_COMMAND="${VSQL} -U $QUERY_USER -w $QUERY_USER_PASSWORD " # UMAR TEMP CHANGE => "${VSQL} -U $QUERY_USER -w $QUERY_USER_PASSWORD "


RAND_ID=$(($RANDOM % 100))
RUN_ID="run_$RAND_ID"
SCRATCH_DIR=${PWD}/$RUN_ID
echo "---------------------------------------------------"
echo "RUN_ID = $RUN_ID"
echo "SCRATCH_DIR = $SCRATCH_DIR"
echo "TARGET_SCHEMA = $TARGET_SCHEMA"
echo "---------------------------------------------------"
rm -rf $SCRATCH_DIR

# Check if the directory can be created
if ! mkdir -p "$SCRATCH_DIR"; then
    echo "Error: Unable to create directory $SCRATCH_DIR. Please check permissions."
    exit 1
fi

START_TIME=$(date +"%Y-%m-%d %H:%m:%S")


echo "+++ Making schema +++"

$VSQL_ADMIN_COMMAND -a -c "create schema if not exists $TARGET_SCHEMA;"
#$VSQL_ADMIN_COMMAND -a -c "grant all on schema $TARGET_SCHEMA to $QUERY_USER"

# TODO: use this table to say which txns we collect
# vsql -a -c "create table if not exists $TARGET_SCHEMA.profile_collection_info(transaction_id int, statement_id int, query_name varchar(128))"

# SOURCE_TABLES="dc_requests_issued dc_query_executions dc_explain_plans query_plan_profiles query_profiles execution_engine_profiles resource_acquisitions query_consumption"
# NOTE that in fact we need ORIGINAL_SCHEMA.TABLE names, will hard-code for now
#SOURCE_TABLES="v_internal.dc_requests_issued v_internal.dc_query_executions v_internal.dc_explain_plans " 
SOURCE_TABLES="v_internal.dc_requests_issued v_internal.dc_query_executions v_internal.dc_explain_plans  v_monitor.query_profiles v_monitor.execution_engine_profiles v_monitor.resource_acquisitions v_monitor.query_consumption v_monitor.query_plan_profiles v_internal.dc_slow_events v_monitor.query_events"
SNAPSHOT_TABLES="v_monitor.host_resources v_monitor.resource_pool_status"

# It would be handy to have tables stored in a list, separate from schemas
for t in $SOURCE_TABLES
do
    echo "-------------------------------------"
    echo "Creating profile destination for $t"
    ORIGINAL_SCHEMA="${t%%.*}"
    TABLE_NAME="${t##*.}"
    echo "Original schema = ${ORIGINAL_SCHEMA}"
    echo "Original table = ${TABLE_NAME}"
    $VSQL_ADMIN_COMMAND -a -c "create table if not exists $TARGET_SCHEMA.$TABLE_NAME as select * from $ORIGINAL_SCHEMA.$TABLE_NAME LIMIT 0;"
    # Be sure to add a column for query_name
    $VSQL_ADMIN_COMMAND -a -c "alter table $TARGET_SCHEMA.$TABLE_NAME add column if not exists query_name varchar(128);"
done

for t in $SNAPSHOT_TABLES
do
echo "-------------------------------------"
    echo "SNAPSHOT TABLE: Creating profile destination for $t"
    ORIGINAL_SCHEMA="${t%%.*}"
    TABLE_NAME="${t##*.}"
    echo "Original schema = ${ORIGINAL_SCHEMA}"
    echo "Original table = ${TABLE_NAME}"
    $VSQL_ADMIN_COMMAND -a -c "create table if not exists $TARGET_SCHEMA.$TABLE_NAME as select * from $ORIGINAL_SCHEMA.$TABLE_NAME LIMIT 0;"
    # Be sure to add a columns for:
    # Transcation id
    # Statemet id
    # Query_name
    $VSQL_ADMIN_COMMAND -a -c "alter table $TARGET_SCHEMA.$TABLE_NAME add column if not exists transaction_id int;"
    $VSQL_ADMIN_COMMAND -a -c "alter table $TARGET_SCHEMA.$TABLE_NAME add column if not exists statement_id int;"
    $VSQL_ADMIN_COMMAND -a -c "alter table $TARGET_SCHEMA.$TABLE_NAME add column if not exists query_name varchar(128);"

done


echo "Creating additional collection info tables"

for tracking_table in "${SQL_DIR}/tables/collect_create_collection_info.sql"
do
    tempfile="${SCRATCH_DIR}/$(basename $tracking_table)"
    sed "s|IMPORT_SCHEMA|${TARGET_SCHEMA}|g" $tracking_table > $tempfile
    $VSQL_ADMIN_COMMAND -a -f "$tempfile"
done 
# TODO: update collection_events with more columns
#
$VSQL_ADMIN_COMMAND -a -c "create table if not exists $TARGET_SCHEMA.collection_events(transaction_id int, statement_id int, table_name varchar (256), operation varchar(128), row_count int);"

PROF_COUNT=0
LINE_COUNT=0

while read -r line;
do
    LINE_COUNT=$(($LINE_COUNT + 1))
    if [[ $line == "#"* ]]; then
        echo "Skipping comment on line num $LINE_COUNT, '$line'"
        continue
    fi
    USER_LABEL=$(echo $line | cut -d '|' -f 1)
    USER_COMMENT=$(echo $line | cut -d '|' -f 2)
    QUERY_FILE=$(echo $line | cut -d '|' -f 3)

    if [ -z "$USER_LABEL" ]; then
        echo "Line $LINE_COUNT has empty user label: '$line'"
        exit 1
    fi

    if [ -z "$USER_COMMENT" ]; then
        echo "Line $LINE_COUNT has empty user comment: '$line'"
        exit 1
    fi

    if [ -z "$QUERY_FILE" ]; then
        echo "Line $LINE_COUNT has empty user comment: '$line'"
        exit 1
    fi

    echo "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
    echo "Query: $USER_LABEL, '$USER_COMMENT', $QUERY_FILE"

    QUERY_FILE_BASENAME=$(basename "$QUERY_FILE")

    echo "Adding profile statement..."
    SCRATCH_QUERY_FILE=${SCRATCH_DIR}/${QUERY_FILE_BASENAME}

    cp -v "${QUERY_FILE}" "${SCRATCH_QUERY_FILE}"

    # The following sed command adds profiling ONCE
    sed -i -r -e "0,/(^[Ww][Ii][Tt][Hh]|^[Ss][Ee][Ll][Ee][Cc][Tt])/{s#(^WITH|^SELECT)#PROFILE \1 #i}" ${SCRATCH_QUERY_FILE}

    # the follow sed command extends the hint to have a label
    if grep -c '/[*][+]' ${SCRATCH_QUERY_FILE}; then
	# Case - there is a hint in the query already
	# INPUT: select /*+opt_dir('V2OptDisableJoinRanks=true')*/ ...
	# OUTPUT: select /*+opt_dir('V2OptDisableJoinRanks=true'), label('CQCS')*/
	# We must extend the query hint: distinct hints are not allowed
	# It follows that there is exactly one hint the input query: otherwise, the
	# query would be invalid
	sed -i -r -e "s#/[*][+](.*)\)[*]/#/*+\1\), label('$USER_LABEL')*/#" ${SCRATCH_QUERY_FILE}
    else
	# Case - there is no hint in the query already
	sed -i -r -e "0,/(^WITH|^SELECT)/{s#(^WITH|^SELECT)# \1 /*+label('$USER_LABEL')*/ #}" ${SCRATCH_QUERY_FILE}
    fi

    echo "Begin query execution"

    PROFILE_NOTICE_FILE=$SCRATCH_DIR/${QUERY_FILE_BASENAME}.prof_msg
    time $VSQL_USER_COMMAND -o dev/null -f ${SCRATCH_QUERY_FILE} 2>> $PROFILE_NOTICE_FILE
    echo "Query execution complete"
    cat $PROFILE_NOTICE_FILE
    QUERY_ID_FILE=${SCRATCH_DIR}/${QUERY_FILE_BASENAME}.qid
    grep '^HINT:' $PROFILE_NOTICE_FILE | sed 's#.*transaction_id=\([0-9]\+\) and statement_id=\([0-9]\+\).*#\1|\2#' > $QUERY_ID_FILE
    combo_tid_sid=$(cat ${QUERY_ID_FILE})
    TXN_ID=`echo $combo_tid_sid | cut -f1 -d '|'`
    STMT_ID=`echo $combo_tid_sid | cut -f2 -d '|'`

    echo "TXN: $TXN_ID"
    echo "STMT: $STMT_ID"
    if [ -z "$TXN_ID" ]; then
	    echo "Error: TXN_ID was empty, combo_tid_sid was $combo_tid_sid"
	    exit 1
    fi
    $VSQL_ADMIN_COMMAND -a -c "insert into $TARGET_SCHEMA.collection_info values ($TXN_ID, $STMT_ID, '$USER_LABEL', '$USER_COMMENT', '$PROJECT_NAME', '$CUSTOMER_NAME'); commit;"

    for t in $SNAPSHOT_TABLES
    do
	echo "---------------------------------------------"
	echo "Collecting from SNAPSHOT Source Table is $t"
	echo "---------------------------------------------"
	ORIGINAL_SCHEMA="${t%%.*}"
	TABLE_NAME="${t##*.}"

	time $VSQL_ADMIN_COMMAND -a -c "insert into $TARGET_SCHEMA.$TABLE_NAME select *, $TXN_ID, $STMT_ID, '$USER_LABEL' from $ORIGINAL_SCHEMA.$TABLE_NAME ; commit;"

    done

    PROF_COUNT=$((PROF_COUNT +1))
    echo "Done with query $USER_LABEL count $PROF_COUNT"

done < "$CONFIG_FILE"

for t in $SOURCE_TABLES
do
    echo "---------------------------------------------"
    echo "Collecting from Source Table is $t"
    echo "---------------------------------------------"
    ORIGINAL_SCHEMA="${t%%.*}"
    TABLE_NAME="${t##*.}"

    # We need to choose which columns we want in the select statement
    # because all columns is too many.
    # In order to choose all cols, we need a definition of the table
    # Then we need to take the list of columns and update them so that 
    # they have the alias 'orig' prepended, 
    # orig.col1, orig.col2
    RAW_COLS=`cat sql/cols/$TABLE_NAME.cols`

    QUALIFIED_COLS=$(echo $RAW_COLS | sed -r 's|([a-zA-Z0-9_]+),|orig.\1,|g' | sed -r 's|,([a-zA-Z0-9_]+)$|,orig.\1|')

    time $VSQL_ADMIN_COMMAND -a -c "insert into $TARGET_SCHEMA.$TABLE_NAME select $QUALIFIED_COLS, cinfo.user_query_label from $ORIGINAL_SCHEMA.$TABLE_NAME as orig join $TARGET_SCHEMA.collection_info as cinfo on orig.transaction_id=cinfo.transaction_id and orig.statement_id=cinfo.statement_id; commit;"

done




echo "BUilding up verification tables"


for t in $SOURCE_TABLES $SNAPSHOT_TABLES
do
    echo "<<<< Checking load info >>>>"
    echo "Source Table is $t"
    ORIGINAL_SCHEMA="${t%%.*}"
    TABLE_NAME="${t##*.}"
    echo "Target is $TABLE_NAME"
    echo "---------------------------------------------"
    time $VSQL_ADMIN_COMMAND -a -c "insert into $TARGET_SCHEMA.collection_events select cinfo.transaction_id, cinfo.statement_id, '$TABLE_NAME', 'collect', count (*) as row_count from $TARGET_SCHEMA.$TABLE_NAME dupe join $TARGET_SCHEMA.collection_info cinfo on dupe.transaction_id=cinfo.transaction_id and dupe.statement_id=cinfo.statement_id group by 1, 2 order by 1,2; commit;"
done

# Show a summary table
$VSQL_ADMIN_COMMAND -a -c "select transaction_id, statement_id, table_name, sum(row_count) from $TARGET_SCHEMA.collection_events group by 1, 2, 3 order by 1, 2, 3"



echo "Done with script collecting into $TARGET_SCHEMA. Profiled ${PROF_COUNT} queries" 