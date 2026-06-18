#!/usr/bin/env bash

_help() {
    cat <<EOF
    $(basename "${BASH_SOURCE[0]}") [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]

    A helper script to compare current spending vs historical

    Options:

    -h, --help      Print this help
    -p, --profile    the aws profile to use (if no profile specified uses default)
    -r, --region    the aws profile to use (if no region specified uses default)
EOF
    exit
}

_params() {

    # default values
    region=''
    profile=''

    while :; do
        case "${1-}" in
        -h | --help) usage ;;
        #-v | --verbose) set -x ;;
        -p | --profile) # aws profile
            profile="--profile ${2-}"
            shift
            ;;
        -r | --region) # aws region
            region="--region ${2-}"
            shift
            ;;
        -g | --granularity)
            granularity="${2-}"
            shift
            ;;
        -sd | --start-date)
            start_date="${2-}"
            shift
            ;;
        -ed | --end-date)
            end_date="${2-}"
            shift
            ;;
        -?*)
            echo "Option: $1 is not recognised"
            exit 1
            ;;
        *) break ;;
        esac
        shift
    done
    args=("$@")
    return 0
}

# function to get the current date
get_current_date() {
    local current_date=$(date +%Y-%m-%d)
    echo $current_date
}

# function to calculate the date one week ago from today
get_one_week_ago() {
    local one_week_ago=$(date -d "1 week ago" +%Y-%m-%d)
    echo $one_week_ago
}

# function to calculate the date two weeks ago from today
get_two_weeks_ago() {
    local two_weeks_ago=$(date -d "2 weeks ago" +%Y-%m-%d)
    echo $two_weeks_ago
}

# function to calculate the date one month ago from today
get_one_month_ago() {
    local one_month_ago=$(date -d "1 month ago" +%Y-%m-%d)
    echo $one_month_ago
}

# function to calculate the date two months ago from today
get_two_months_ago() {
    local two_months_ago=$(date -d "2 months ago" +%Y-%m-%d)
    echo $two_months_ago
}

# function to calculate the date six months ago from today
get_six_months_ago() {
    local six_months_ago=$(date -d "6 months ago" +%Y-%m-%d)
    echo $six_months_ago
}

# function to get current time period spending.
get_spending() {
    local start_date=$1
    local end_date=$2
    local granularity=$3
    local metrics="BlendedCost"
    local filter="{\"Not\": {\"Dimensions\": {\"Key\": \"RECORD_TYPE\",\"Values\": [\"Credit\",\"Refund\",\"Tax\"]}}}"

    aws ${profile} ${region} ce get-cost-and-usage \
        --time-period Start=${start_date},End=${end_date} \
        --granularity ${granularity} \
        --metrics ${metrics} \
        --filter "${filter}"
}

# if start/end date not specified then use default values
if [ -z "$start_date" ]; then
    start_date=$(get_six_months_ago)
fi
if [ -z "$end_date" ]; then
    end_date=$(get_one_month_ago)
fi

# if granularity not specified then use default value
if [ -z "$granularity" ]; then
    granularity="MONTHLY"
fi


# # get_current_date to a string variable
# current_date=$(get_current_date)
# # get_one_week_ago to a string variable
# one_week_ago=$(get_one_week_ago)
# # get_two_weeks_ago to a string variable
# two_weeks_ago=$(get_two_weeks_ago)
# # get_one_month_ago to a string variable
# one_month_ago=$(get_one_month_ago)
# # get_two_months_ago to a string variable
# two_months_ago=$(get_two_months_ago)

spending_json=$(get_spending $start_date $end_date $granularity)
cost_data_points=$(echo $spending_json | jq -r '.ResultsByTime[].Total.BlendedCost.Amount')
cost_data_points=$(echo $cost_data_points | tr '\n' ' ')
cost_data_point_first=$(echo $spending_json | jq -r '.ResultsByTime[0].Total.BlendedCost.Amount')
cost_data_point_last=$(echo $spending_json | jq -r '.ResultsByTime[-2].Total.BlendedCost.Amount')

# send cost_data_points to python and ask for the mean mode and median
# mean=$(python3 -c "import statistics; print(statistics.mean($cost_data_points))")
# mode=$(python3 -c "import statistics; print(statistics.mode($cost_data_points))")
# median=$(python3 -c "import statistics; print(statistics.median($cost_data_points))")
# mean=$(python3 -c "print($cost_data_points)")
# mode=$(python3 -c "print($cost_data_points)")
# median=$(python3 -c "print($cost_data_points)")
# echo $mean
# echo $mode
# echo $median

# python3 -c "import sys; input_str=\"$cost_data_points\"; print(input_str)"

# # function get float variable array from python
# get_float_array() {
#     local floatvar=$(python3 -c "import sys; input_str=$1; res = [float(idx) for idx in input_str.split(' ')]; print(str(res))")
#     echo $floatvar
# }
# get_mean_value() {
#     local meanvar=$(python3 -c "import statistics; print(statistics.mean($1))")
#     echo $meanvar
# }
# get_median_value() {
#     local medianvar=$(python3 -c "import statistics; print(statistics.median($1))")
#     echo $medianvar
# }

get_diff_value() {
    local diffvar=$(python3 -c "diff=abs(int($1)-int($2)); print(round(diff,2))")
    echo $diffvar
}

# calculate the percentage difference between two values
get_percentage_diff() {
    local diffvar=$(python3 -c "perc=round(($2 - $1) / abs($1) * 100, 2); print(perc)")
    echo $diffvar
}

# current cost
echo "Current Cost: $cost_data_point_last"
# previous cost
echo "Previous Cost: $cost_data_point_first"
# difference
echo "Difference: \$ $(get_diff_value $cost_data_point_first $cost_data_point_last )"
# percentage difference
echo "Percentage Difference: $(get_percentage_diff  $cost_data_point_first $cost_data_point_last )%"



