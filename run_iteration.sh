zig build
# run below command 10 times with sleep 1 second per iteration
# because of unstability of implementation, it may fail sometimes
SUCCESS=0
FAILED=0
SUCCESS_INDEX=()
for i in {1..10}; do 
echo "Iteration $i"
./zig-out/bin/zigh2 shiguredo.jp > "test_$i.html"
if [ $? -ne 0 ]; then
    echo "Failed on iteration $i"
    FAILED=$((FAILED+1))
else
    echo "Success on iteration $i"
    SUCCESS=$((SUCCESS+1))
    SUCCESS_INDEX+=($i)
fi
done
echo "Success: $SUCCESS Failed: $FAILED"

for i in "${SUCCESS_INDEX[@]}"; do
echo "Showing test_$i.html"
cat "test_$i.html"
done
