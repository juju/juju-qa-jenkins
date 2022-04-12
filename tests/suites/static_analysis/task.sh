test_static_analysis() {
    if [ "$(skip 'test_static_analysis')" ]; then
        echo "==> TEST SKIPPED: skip static analysis"
        return
    fi

    test_static_analysis_shell
    test_static_analysis_yaml
}
