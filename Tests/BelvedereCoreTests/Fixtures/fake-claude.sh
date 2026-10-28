# Finto `claude` per i test di StreamProcess: risponde riga per riga.
while IFS= read -r line; do
  case "$line" in
    big) printf '{"type":"big","data":"'; head -c 5000000 /dev/zero | tr '\0' 'a'; printf '"}\n' ;;
    die) echo "Invalid API key · Please run /login" >&2; exit 3 ;;
    hang) trap '' INT; sleep 60 ;;
    *) printf '{"type":"echo","got":"%s"}\n' "$line" ;;
  esac
done
