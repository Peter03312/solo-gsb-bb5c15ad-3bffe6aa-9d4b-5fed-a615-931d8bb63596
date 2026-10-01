#!/usr/bin/env bash
# 凭证换发端到端示例：
#   单快照令牌换发（继承适用快照/原绝对到期/已用次数与剩余额度）->
#   相同请求标识重试回放首次结果 -> 旧凭证立即 403、新凭证继续可用 ->
#   已撤销/额度耗尽/未知凭证换发被拒（409/404）->
#   多快照共享凭证换发（继承冻结清单与共享已用次数）->
#   清单中一项撤回后仍可换发、撤回项继续不可读且不扣额度 ->
#   不同请求标识并发换发只有一次成功，其余 409
# 依赖：curl、jq
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
SERVICE_KEY="${SERVICE_KEY:-dev-service-key-change-me}"
ALICE_PW="${ALICE_PW:-alice-pw}"   # operator
BOB_PW="${BOB_PW:-bob-pw}"         # reviewer
AUTH=(-H "X-Service-Key: ${SERVICE_KEY}" -H "Content-Type: application/json")

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
code() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }
new_request_id() { python3 -c 'import uuid; print(uuid.uuid4())'; }

step "1. 创建记录并发布版本 1，签发一支上限 5 次的单快照令牌"
CREATE=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "患者张三，身份证号 110101199003077777，联系电话 13800001111。",
  "intervals": [{"start": 2, "end": 4}, {"start": 10, "end": 28}, {"start": 34, "end": 45}]
}')
RECORD_ID=$(echo "${CREATE}" | jq -r .record_id)
PUB=$(curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/publish" "${AUTH[@]}" \
  -d '{"version": 1, "max_reads": 5}')
SID=$(echo "${PUB}" | jq -r .snapshot_id)
TOKEN=$(echo "${PUB}" | jq -r .token)
echo "快照 ${SID}，令牌上限 5 次"

step "2. 先成功读取 2 次（已用 2 / 剩余 3），随后换发"
curl -sS "${BASE_URL}/public/snapshots/${SID}?token=${TOKEN}" | jq .
curl -sS "${BASE_URL}/public/snapshots/${SID}?token=${TOKEN}" | jq .

REQ_ID=$(new_request_id)
echo "请求标识 request_id=${REQ_ID}"
ROT=$(curl -sS -X POST "${BASE_URL}/credentials/rotate" "${AUTH[@]}" \
  -d "{\"credential\": \"${TOKEN}\", \"request_id\": \"${REQ_ID}\"}")
echo "${ROT}" | jq .
NEW_TOKEN=$(echo "${ROT}" | jq -r .new_credential)
echo "继承结果：reads_used=$(echo "${ROT}" | jq .reads_used) / remaining_reads=$(echo "${ROT}" | jq .remaining_reads)"

step "3. 相同原凭证 + 相同请求标识重试：原样回放首次结果（new_credential 不变，不再次换发）"
RETRY=$(curl -sS -X POST "${BASE_URL}/credentials/rotate" "${AUTH[@]}" \
  -d "{\"credential\": \"${TOKEN}\", \"request_id\": \"${REQ_ID}\"}")
echo "${RETRY}" | jq '{request_id, kind, new_credential, reads_used, remaining_reads}'
[ "${RETRY}" = "${ROT}" ] && echo "重试响应与首次完全一致"

step "4. 旧凭证提交后不能再读取（模糊 403）；新凭证继续读同一快照并接着继承的额度扣次"
printf '旧凭证读取: HTTP %s\n' "$(code "${BASE_URL}/public/snapshots/${SID}?token=${TOKEN}")"
curl -sS "${BASE_URL}/public/snapshots/${SID}?token=${NEW_TOKEN}" | jq '{status, redacted_text}'
curl -sS "${BASE_URL}/tokens/${NEW_TOKEN}" "${AUTH[@]}" \
  | jq '{max_reads, reads_used, remaining_reads, active}'

step "5. 换发凭证可再次换发；已撤销/耗尽/未知/缺密钥的换发被拒"
ROT2=$(curl -sS -X POST "${BASE_URL}/credentials/rotate" "${AUTH[@]}" \
  -d "{\"credential\": \"${NEW_TOKEN}\", \"request_id\": \"$(new_request_id)\"}")
echo "${ROT2}" | jq '{kind, reads_used, remaining_reads}'
# 已被上一次换发停用的凭证再换发 -> 409
printf '已换发凭证再换发: HTTP %s\n' "$(code -X POST "${BASE_URL}/credentials/rotate" "${AUTH[@]}" \
  -d "{\"credential\": \"${NEW_TOKEN}\", \"request_id\": \"$(new_request_id)\"}")"
# 先撤销再换发 -> 409
REVOKE_TOK=$(curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/publish" "${AUTH[@]}" \
  -d '{"version": 1, "max_reads": 2}' | jq -r .token)
curl -sS -X POST "${BASE_URL}/tokens/${REVOKE_TOK}/revoke" "${AUTH[@]}" >/dev/null
printf '已撤销凭证换发:   HTTP %s\n' "$(code -X POST "${BASE_URL}/credentials/rotate" "${AUTH[@]}" \
  -d "{\"credential\": \"${REVOKE_TOK}\", \"request_id\": \"$(new_request_id)\"}")"
# 读到额度耗尽：读取 403，换发 409
EXH_TOK=$(curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/publish" "${AUTH[@]}" \
  -d '{"version": 1, "max_reads": 1}' | jq -r .token)
curl -sS "${BASE_URL}/public/snapshots/${SID}?token=${EXH_TOK}" >/dev/null
printf '耗尽凭证读取:     HTTP %s，换发: HTTP %s\n' \
  "$(code "${BASE_URL}/public/snapshots/${SID}?token=${EXH_TOK}")" \
  "$(code -X POST "${BASE_URL}/credentials/rotate" "${AUTH[@]}" \
      -d "{\"credential\": \"${EXH_TOK}\", \"request_id\": \"$(new_request_id)\"}")"
# 未知凭证 -> 404；缺服务密钥 -> 401
printf '未知凭证换发:     HTTP %s\n' "$(code -X POST "${BASE_URL}/credentials/rotate" "${AUTH[@]}" \
  -d '{"credential": "not-an-existing-credential", "request_id": "'"$(new_request_id)"'"}')"
NEW_TOKEN2=$(echo "${ROT2}" | jq -r .new_credential)
printf '缺服务密钥:       HTTP %s\n' "$(code -X POST "${BASE_URL}/credentials/rotate" \
  -H 'Content-Type: application/json' \
  -d "{\"credential\": \"${NEW_TOKEN2}\", \"request_id\": \"$(new_request_id)\"}")"

step "6. 多快照共享凭证：准备第二个快照，申请-复核签发共享凭证（总额度 5）"
CREATE2=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "完全不同的新原文，敏感词ABC。", "intervals": [{"start": 9, "end": 15}]}')
RID2=$(echo "${CREATE2}" | jq -r .record_id)
SID2=$(curl -sS -X POST "${BASE_URL}/records/${RID2}/publish" "${AUTH[@]}" \
  -d '{"version": 1, "max_reads": 100}' | jq -r .snapshot_id)
BRID=$(curl -sS -X POST "${BASE_URL}/bundle-requests" \
  -u "alice:${ALICE_PW}" -H 'Content-Type: application/json' \
  -d "{\"snapshot_ids\": [\"${SID}\", \"${SID2}\"], \"max_reads\": 5}" | jq -r .request_id)
BAPP=$(curl -sS -X POST "${BASE_URL}/bundle-requests/${BRID}/approve" -u "bob:${BOB_PW}")
BID=$(echo "${BAPP}" | jq -r .bundle_id)
CRED=$(echo "${BAPP}" | jq -r .credential)
echo "共享凭证 ${CRED}（bundle ${BID}），清单 [${SID}, ${SID2}]"

step "7. 两个清单快照各成功读 1 次（共享已用 2），换发共享凭证"
curl -sS "${BASE_URL}/public/snapshots/${SID}?token=${CRED}"  >/dev/null
curl -sS "${BASE_URL}/public/snapshots/${SID2}?token=${CRED}" >/dev/null
BROT=$(curl -sS -X POST "${BASE_URL}/credentials/rotate" "${AUTH[@]}" \
  -d "{\"credential\": \"${CRED}\", \"request_id\": \"$(new_request_id)\"}")
echo "${BROT}" | jq .
NEW_CRED=$(echo "${BROT}" | jq -r .new_credential)
echo "继承冻结清单顺序与共享已用次数：snapshot_ids=$(echo "${BROT}" | jq -c .snapshot_ids)，reads_used=$(echo "${BROT}" | jq .reads_used)"
printf '旧共享凭证读取: HTTP %s\n' "$(code "${BASE_URL}/public/snapshots/${SID}?token=${CRED}")"
curl -sS "${BASE_URL}/public/snapshots/${SID2}?token=${NEW_CRED}" | jq '{status, redacted_text}'

step "8. 清单中一项快照撤回：共享凭证仍可换发，撤回项继续 403 且不扣额度，另一项可读"
curl -sS -X POST "${BASE_URL}/snapshots/${SID2}/withdraw" "${AUTH[@]}" \
  -d '{"reason":"该版本不再对外提供"}' | jq '{snapshot_id, status}'
BROT2=$(curl -sS -X POST "${BASE_URL}/credentials/rotate" "${AUTH[@]}" \
  -d "{\"credential\": \"${NEW_CRED}\", \"request_id\": \"$(new_request_id)\"}")
echo "${BROT2}" | jq '{kind, snapshot_ids, reads_used, remaining_reads}'
NEW_CRED2=$(echo "${BROT2}" | jq -r .new_credential)
printf '撤回项读取:     HTTP %s（不扣额度）\n' "$(code "${BASE_URL}/public/snapshots/${SID2}?token=${NEW_CRED2}")"
curl -sS "${BASE_URL}/public/snapshots/${SID}?token=${NEW_CRED2}" | jq '{status, redacted_text}'

step "9. 不同请求标识并发换发同一凭证：恰好一次成功，其余 409"
# 准备一枚全新的共享凭证（需要两个未撤回快照；SID2 已撤回，故新建一条记录）
CREATE3=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "并发换发演示专用记录。", "intervals": [{"start": 0, "end": 2}]}')
SID4=$(curl -sS -X POST "${BASE_URL}/records/$(echo "${CREATE3}" | jq -r .record_id)/publish" \
  "${AUTH[@]}" -d '{"version": 1, "max_reads": 100}' | jq -r .snapshot_id)
BRID3=$(curl -sS -X POST "${BASE_URL}/bundle-requests" \
  -u "alice:${ALICE_PW}" -H 'Content-Type: application/json' \
  -d "{\"snapshot_ids\": [\"${SID}\", \"${SID4}\"], \"max_reads\": 50}" | jq -r .request_id)
CRED3=$(curl -sS -X POST "${BASE_URL}/bundle-requests/${BRID3}/approve" \
  -u "bob:${BOB_PW}" | jq -r .credential)

TMPDIR_CONC=$(mktemp -d)
for i in $(seq 1 8); do
  (
    curl -sS -o "${TMPDIR_CONC}/out.${i}" -w '%{http_code}' -X POST \
      "${BASE_URL}/credentials/rotate" "${AUTH[@]}" \
      -d "{\"credential\": \"${CRED3}\", \"request_id\": \"$(new_request_id)\"}" \
      > "${TMPDIR_CONC}/code.${i}"
  ) &
done
wait
echo "并发 8 个不同请求标识的换发结果统计（次数 状态码）："
for i in $(seq 1 8); do cat "${TMPDIR_CONC}/code.${i}"; echo; done | sort | uniq -c
WINNER=""
for i in $(seq 1 8); do
  if [ "$(cat "${TMPDIR_CONC}/code.${i}")" = "200" ]; then
    WINNER=$(cat "${TMPDIR_CONC}/out.${i}" | jq -r .new_credential)
  fi
done
echo "唯一成功换发的新凭证：${WINNER}"
printf '旧凭证随后读取: HTTP %s（换发提交后旧凭证已停用）\n' \
  "$(code "${BASE_URL}/public/snapshots/${SID}?token=${CRED3}")"
rm -rf "${TMPDIR_CONC}"

printf '\n\033[1m凭证换发演示完成。\033[0m\n'
