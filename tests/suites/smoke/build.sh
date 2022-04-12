run_build() {
    cat << EOF > "${TEST_DIR}"/jenkins-jjb
[job_builder]
ignore_cache=True
keep_descriptions=False
recursive=False
allow_duplicates=False
EOF

    OUT=$(jenkins-jobs --conf "${TEST_DIR}" test jobs/ci-run 2>&1 || true)
    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        echo ""
        echo "$(red 'Found some issues:')"
        echo "\\n${OUT}"
        exit 1
    fi
}

test_build() {
    if [ "$(skip 'test_build')" ]; then
        echo "==> TEST SKIPPED: smoke build tests"
        return
    fi

    (
        set_verbosity

        cd .. || exit

        # Check that build runs
        run "run_build"
    )
}
