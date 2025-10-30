#!/bin/bash

echo "Testing GUI threading fix..."
echo "Starting Krowno GUI..."

# Start the GUI in background
./zig-out/bin/krowno &
GUI_PID=$!

echo "GUI started with PID: $GUI_PID"
echo "GUI should be responsive now - backup operations will run in separate threads"
echo "Press Ctrl+C to stop the test"

# Wait for user to stop
trap "echo 'Stopping GUI...'; kill $GUI_PID; exit 0" INT

# Keep the script running
while true; do
    sleep 1
    if ! kill -0 $GUI_PID 2>/dev/null; then
        echo "GUI process ended"
        break
    fi
done
