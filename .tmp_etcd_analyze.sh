#!/bin/sh
f=/tmp/etcd_metrics.prom

echo "=== etcd_request_errors_total (sum over all verb/resource) ==="
awk '/^etcd_request_errors_total\{/ {s+=$NF} END{printf "  total errors: %.0f\n", s}' "$f"

echo "=== etcd_requests_total (sum) ==="
awk '/^etcd_requests_total\{/ {s+=$NF} END{printf "  total requests (counter): %.0f\n", s}' "$f"

echo "=== etcd_request_duration_seconds (aggregate avg) ==="
awk '
/^etcd_request_duration_seconds_sum\{/   {sum+=$NF}
/^etcd_request_duration_seconds_count\{/ {cnt+=$NF}
END{ if(cnt>0) printf "  sum=%.4f s, count=%.0f, avg=%.6f s/request (%.1f us)\n", sum, cnt, sum/cnt, sum/cnt*1000000 }
' "$f"

echo "=== etcd_request_duration_seconds buckets (cumulative, all label sets summed) ==="
for le in 0.001 0.005 0.01 0.05 0.1 0.5 1 +Inf; do
  awk -v le="$le" '
    BEGIN{ esc=le; gsub(/\+/,"\\+",esc) }
    $0 ~ ("^etcd_request_duration_seconds_bucket\\{.*le=\""esc"\"") {s+=$NF}
    END{ printf "  le=%-5s cumulative: %.0f\n", le, s }
  ' "$f"
done
