test_smoke() {
    if [ "$(skip 'test_smoke')" ]; then
        echo "==> TEST SKIPPED: smoke tests"
        return
    fi

    test_build
}
