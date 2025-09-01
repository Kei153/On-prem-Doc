#!/bin/bash

# 설정
ALIAS="myminio"
BUCKET_PREFIX="test1/access-test/"
TRACE_DIR="$HOME/minio-trace"
DB_DIR="$HOME/trace-db"
LOG_FILE="${TRACE_DIR}/trace-$(date +%Y%m%d-%H%M%S).json"
DB_FILE="$DB_DIR/last-access.json"

MINIO_ENDPOINT="https://kei-test-minio-api.laon-ezplanet.com"
MINIO_ACCESS_KEY="kei"
MINIO_SECRET_KEY="laon0118"
WORK_TIME=15  # trace 수집 시간 (초 단위)

# 디렉토리 보장
mkdir -p "$TRACE_DIR"
mkdir -p "$DB_DIR"
[ -f "$DB_FILE" ] || echo "{}" > "$DB_FILE"

# mc alias 등록
mc alias set myminio "$MINIO_ENDPOINT" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" --api S3v4

echo "🎯 MinIO trace 시작... $WORK_TIME 초간 수집합니다."
echo "📂 대상 버킷: $BUCKET_PREFIX"
echo "📝 로그 파일: $LOG_FILE"

# trace 수집 - 실시간 필터링으로 부하 최소화
echo "🚀 trace 수집 시작 (실시간 필터링으로 부하 최소화)..."

# 🔥 중요: 실시간으로 우리 버킷만 필터링하여 메모리/디스크 사용량 최소화
gtimeout "$WORK_TIME" stdbuf -oL mc admin trace $ALIAS --verbose --json | \
  grep --line-buffered -i "kei-minio-test" | \
  tee "$LOG_FILE"

echo "📊 수집된 kei-minio-test 관련 로그: $(wc -l < "$LOG_FILE" 2>/dev/null || echo "0") 줄"

# 추가 필터링: hot-test 폴더만
echo "🔍 hot-test 폴더 관련 로그만 필터링 중..."
grep -i "hot-test" "$LOG_FILE" > "${LOG_FILE}.filtered" 2>/dev/null || echo "" > "${LOG_FILE}.filtered"

echo "📊 최종 필터링된 로그: $(wc -l < "${LOG_FILE}.filtered") 줄"

# trace 로그 확인
echo "🔍 수집된 trace 로그 확인:"
if [ -s "${LOG_FILE}.filtered" ]; then
    echo "✅ 필터링된 로그 파일 크기: $(wc -l < "${LOG_FILE}.filtered") 줄"
    echo "📊 trace 수집 완료 (상세 로그는 생략)"
else
    echo "⚠️ 필터링된 trace 로그가 비어있습니다."
    
    if [ -s "$LOG_FILE" ]; then
        echo "📄 전체 로그 크기: $(wc -l < "$LOG_FILE") 줄"
        echo "📊 trace 수집 완료"
    else
        echo "❌ trace 수집 실패"
    fi
fi

# DB 백업
cp "$DB_FILE" "$DB_FILE.tmp"

# trace 로그 처리 - 간소화 (상세 출력 제거)
echo "📊 trace 로그 처리 중..."
PROCESSED_COUNT=0

for TRACE_FILE in $(ls -1 "$TRACE_DIR"/trace-*.json 2>/dev/null | sort); do
  if [ -f "$TRACE_FILE" ] && [ -s "$TRACE_FILE" ]; then
    # 상세 출력 제거, 처리만 진행
    while read -r line; do
      if [ -n "$line" ]; then
        path=$(echo "$line" | jq -r 'select(.path and .time) | .path // empty' 2>/dev/null)
        time=$(echo "$line" | jq -r 'select(.path and .time) | .time // empty' 2>/dev/null)

        if [ -n "$path" ] && [ -n "$time" ] && [ "$path" != "null" ] && [ "$time" != "null" ] && [ "$path" != "empty" ] && [ "$time" != "empty" ]; then
          # 🔥 파일만 처리 (버킷/폴더 경로 제외)
          if [[ "$path" == */hot-test/* ]] && [[ "$path" != */ ]]; then
            # 시간 정리 (타임존 정보만 제거)
            clean_time=$(echo "$time" | sed 's/Z$//' | sed 's/+[0-9][0-9]:[0-9][0-9]$//' | sed 's/\.[0-9]*//g')
            
            # 🔥 간단한 UTC → KST 변환 (현재 시간 사용)
            final_time=$(date '+%Y-%m-%dT%H:%M:%S')
            
            existing_time=$(jq -r --arg path "$path" '.[$path] // ""' "$DB_FILE.tmp")
            
            if [ -z "$existing_time" ] || [[ "$final_time" > "$existing_time" ]]; then
              jq --arg path "$path" --arg time "$final_time" '.[$path] = $time' "$DB_FILE.tmp" > "$DB_FILE.tmp2" && mv "$DB_FILE.tmp2" "$DB_FILE.tmp"
              PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
            fi
          fi
        fi
      fi
    done < "$TRACE_FILE"
  fi
done

mv "$DB_FILE.tmp" "$DB_FILE"
echo "✅ trace 로그 병합 완료. 처리된 기록: $PROCESSED_COUNT개"

# DB 정리
TOTAL_FILES=$(jq 'length' "$DB_FILE")
echo "📊 DB에 기록된 파일 수: $TOTAL_FILES"

if [ "$TOTAL_FILES" -gt 0 ]; then
  echo "🧹 DB 정리 중..."
  
  CLEANED_FILE="$DB_FILE.cleaned"
  rm -f "$CLEANED_FILE"
  echo "{}" > "$CLEANED_FILE"
  
  # 임시 파일로 존재하는 파일만 복사
  temp_list="/tmp/valid_files_$$"
  jq -r 'keys[]' "$DB_FILE" > "$temp_list"
  
  while read -r path; do
    if mc stat "myminio${path}" > /dev/null 2>&1; then
      timestamp=$(jq -r --arg p "$path" '.[$p]' "$DB_FILE")
      jq --arg p "$path" --arg t "$timestamp" '. + {($p): $t}' "$CLEANED_FILE" > "$CLEANED_FILE.tmp" && mv "$CLEANED_FILE.tmp" "$CLEANED_FILE"
    fi
  done < "$temp_list"
  
  rm -f "$temp_list"
  
  CLEANED_COUNT=$(jq 'length' "$CLEANED_FILE" 2>/dev/null || echo "0")
  
  if [ "$CLEANED_COUNT" -gt 0 ]; then
    mv "$CLEANED_FILE" "$DB_FILE"
    echo "✅ DB 정리 완료. 유효한 파일: $CLEANED_COUNT개"
  else
    echo "{}" > "$DB_FILE"
  fi
  
  rm -f "$CLEANED_FILE" "$CLEANED_FILE.tmp"
else
  echo "ℹ️ DB가 비어있습니다."
fi

# 신규 파일 검색
echo "📦 신규 파일 검색 중..."
FOUND_FILES=0

temp_find="/tmp/new_files_$$"
mc find myminio/kei-minio-test/hot-test/ --name '*' --json 2>/dev/null > "$temp_find"

while read -r line; do
  if [ -n "$line" ]; then
    filepath=$(echo "$line" | jq -r '.key | sub("^myminio/"; "") // empty' 2>/dev/null)
    
    if [ -n "$filepath" ] && [ "$filepath" != "null" ] && [ "$filepath" != "empty" ]; then
      fullpath="/$filepath"
      
      if ! jq -e --arg p "$fullpath" 'has($p)' "$DB_FILE" > /dev/null; then
        if mc stat "$ALIAS/$filepath" > /dev/null 2>&1; then
          lastmod=$(mc stat "$ALIAS/$filepath" --json 2>/dev/null | jq -r '.lastModified // empty')
          if [ -n "$lastmod" ] && [ "$lastmod" != "null" ] && [ "$lastmod" != "empty" ]; then
            # 🔥 타임존 정보만 제거 (시간 변환 없음)
            clean_time=$(echo "$lastmod" | sed 's/+[0-9][0-9]:[0-9][0-9]$//' | sed 's/Z$//')
            
            echo "🔍 신규 파일 추가: $fullpath ($clean_time)"
            jq --arg p "$fullpath" --arg t "$clean_time" '. + {($p): $t}' "$DB_FILE" > "$DB_FILE.tmp" && mv "$DB_FILE.tmp" "$DB_FILE"
            FOUND_FILES=$((FOUND_FILES + 1))
          fi
        fi
      fi
    fi
  fi
done < "$temp_find"

rm -f "$temp_find"
echo "✅ 신규 파일 검색 완료. 추가된 파일: $FOUND_FILES개"

# 접근 감지
echo "🔍 파일 접근 감지 중..."
UPDATED_FILES=0

# 🔥 중요: 실제 접근된 파일만 기록하기 위해 접근된 경로를 먼저 수집
accessed_files_temp="/tmp/accessed_files_$"
echo "" > "$accessed_files_temp"

for TRACE_FILE in "$TRACE_DIR"/trace-*.json; do
  if [ -f "$TRACE_FILE" ] && [ -s "$TRACE_FILE" ]; then
    echo "🔍 $TRACE_FILE에서 접근 기록 검색 중..."
    
    while read -r line; do
      if [ -n "$line" ]; then
        # API 호출이면서 우리 버킷 경로를 포함하는 라인만
        if echo "$line" | grep -q '"type":"API"' && echo "$line" | grep -qi "kei-minio-test/hot-test"; then
          path=$(echo "$line" | jq -r '.path // empty' 2>/dev/null)
          api=$(echo "$line" | jq -r '.api // empty' 2>/dev/null)
          request_path=$(echo "$line" | jq -r '.requestPath // empty' 2>/dev/null)
          
          if [ -n "$path" ] && [ "$path" != "null" ] && [ "$path" != "empty" ]; then
            # API 요청 경로와 파일 경로가 정확히 일치하는 경우만 처리
            if [ -n "$request_path" ] && [[ "$request_path" == *"$path"* ]]; then
              echo "📂 trace에서 접근 감지: $path (API: $api, Request: $request_path)"
              echo "$path" >> "$accessed_files_temp"
            fi
          fi
        fi
      fi
    done < "$TRACE_FILE"
  fi
done

# 중복 제거하고 실제 접근된 파일들만 처리
if [ -s "$accessed_files_temp" ]; then
  sort "$accessed_files_temp" | uniq > "$accessed_files_temp.uniq"
  
  echo "📊 실제 접근된 파일들:"
  cat "$accessed_files_temp.uniq"
  
  # 접근된 파일들만 현재 시간으로 업데이트
  while read -r accessed_path; do
    if [ -n "$accessed_path" ] && jq -e --arg p "$accessed_path" 'has($p)' "$DB_FILE" > /dev/null; then
      current_time=$(date '+%Y-%m-%dT%H:%M:%S')
      echo "🔄 접근 시간 업데이트: $accessed_path -> $current_time"
      jq --arg p "$accessed_path" --arg t "$current_time" '.[$p] = $t' "$DB_FILE" > "$DB_FILE.tmp" && mv "$DB_FILE.tmp" "$DB_FILE"
      UPDATED_FILES=$((UPDATED_FILES + 1))
    fi
  done < "$accessed_files_temp.uniq"
  
  rm -f "$accessed_files_temp.uniq"
else
  echo "📋 trace 로그에서 접근 기록을 찾지 못했습니다."
fi

rm -f "$accessed_files_temp"

echo "✅ 접근 시간 업데이트 완료. 업데이트된 파일: $UPDATED_FILES개"
echo "📋 최종 last-access.json:"
cat "$DB_FILE"

#-----------------------------------------기존 trace 로그 파일 정리
echo "🧹 오래된 trace 로그 파일 정리 중..."

# trace 로그 파일 목록을 생성일 기준으로 정렬
trace_files=$(ls -t "$TRACE_DIR"/trace-*.json 2>/dev/null)
file_count=$(echo "$trace_files" | wc -l)

if [ "$file_count" -gt 10 ]; then
  echo "📊 현재 trace 로그 파일 수: $file_count"
  echo "🔍 최근 10개 파일만 유지하고 나머지 삭제..."
  
  # 최근 5개를 제외한 나머지 파일 삭제
  echo "$trace_files" | tail -n +6 | while read -r file; do
    if [ -f "$file" ]; then
      echo "🗑️ 삭제: $file"
      rm -f "$file"
      # filtered 파일도 함께 삭제
      rm -f "${file}.filtered" 2>/dev/null
    fi
  done
  
  remaining_files=$(ls -1 "$TRACE_DIR"/trace-*.json 2>/dev/null | wc -l)
  echo "✅ 정리 완료. 남은 trace 로그 파일: $remaining_files개"
else
  echo "ℹ️ trace 로그 파일이 10개 이하입니다. 정리가 필요하지 않습니다."
fi

#------------------------------------------버킷 처리(이건 vm 으로 test 필요)
# echo "🔍 버킷 상태 확인 중..."

# # DB_FILE에서 최근 24시간 이내 업데이트된 파일이 있는지 확인
# current_time=$(date '+%Y-%m-%dT%H:%M:%S')
# has_recent_access=false

# while IFS= read -r filepath; do
#   file_time=$(jq -r --arg p "$filepath" '.[$p]' "$DB_FILE")
  
#   # 24시간을 초 단위로 계산 (86400초)
#   time_diff=$(( $(date -j -f '%Y-%m-%dT%H:%M:%S' "$current_time" +%s) - $(date -j -f '%Y-%m-%dT%H:%M:%S' "$file_time" +%s) ))
  
#   if [ "$time_diff" -le 86400 ]; then
#     has_recent_access=true
#     echo "📎 최근 접근 파일 발견: $filepath (${time_diff}초 전)"
#     break
#   fi
# done < <(jq -r 'keys[]' "$DB_FILE")

# if [ "$has_recent_access" = true ]; then
#   echo "✅ 최근 접근 기록이 있어 버킷을 유지합니다: $BUCKET_PREFIX"
# else
#   echo "⚠️ 최근 24시간 동안 접근 기록이 없습니다."
#   echo "🗑️ 버킷 삭제 시작: $BUCKET_PREFIX"
  
#   if mc rm --recursive --force "myminio/$BUCKET_PREFIX" > /dev/null 2>&1; then
#     echo "✅ 버킷 삭제 완료"
#     # DB 파일 초기화
#     echo "{}" > "$DB_FILE"
#   else
#     echo "❌ 버킷 삭제 실패"
#   fi
# fi

