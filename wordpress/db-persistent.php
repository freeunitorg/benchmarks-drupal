<?php
/**
 * A wp-content/db.php drop-in that makes the database connection persistent.
 *
 * WordPress 7.1.3's wpdb has no persistent-connection support: wp-includes/class-wpdb.php
 * has no "persistent" branch, and parse_db_host() regex-matches host[:port] so a
 * "p:db" DB_HOST yields the host "p" and drops the rest. A drop-in is the supported
 * seam: db_connect() is overridden to open a mysqli handle with the "p:" prefix,
 * which only pays off when the PHP process survives between requests -- php-fpm,
 * mod_php and FreeUnit's application workers all do.
 *
 * Select it with WP_PERSISTENT=1 at site build. The only differences from a normal
 * installation are this file and DB_HOST, so a pair of sites isolates the effect.
 */

declare(strict_types=1);

if (!class_exists('wpdb')) {
    require_once ABSPATH . WPINC . '/class-wpdb.php';
}

class FU_Persistent_WPDB extends wpdb {

    /**
     * {@inheritdoc}
     */
    public function db_connect( $allow_bail = true ) {
        $this->is_mysql = true;
        $client_flags = defined('MYSQL_CLIENT_FLAGS') ? MYSQL_CLIENT_FLAGS : 0;
        mysqli_report(MYSQLI_REPORT_OFF);

        $host_data = $this->parse_db_host($this->dbhost);
        if (!$host_data) {
            return false;
        }
        [$host, $port, $socket, $is_ipv6] = $host_data;
        $host = $is_ipv6 && !empty($host) ? "[$host]" : $host;

        // The one difference from core: the "p:" prefix asks mysqli for a handle
        // that outlives the request inside this worker process.
        $this->dbh = mysqli_init();
        if (!$this->dbh) {
            return false;
        }
        $connected = @mysqli_real_connect($this->dbh, 'p:' . $host, $this->dbuser, $this->dbpassword, null, $port, $socket, $client_flags);
        if (!$connected) {
            $this->dbh = null;
            return $allow_bail ? $this->bail(sprintf(
                '<h1>Error establishing a database connection</h1><p>Persistent connection to %s failed: %s</p>',
                htmlspecialchars($this->dbhost, ENT_QUOTES), mysqli_connect_error()
            )) : false;
        }
        // wpdb::$has_connected is private and is only read by the core db_connect()
        // this method replaces, so there is nothing to set here.
        $this->set_charset($this->dbh);
        return true;
    }

}

$wpdb = new FU_Persistent_WPDB(DB_USER, DB_PASSWORD, DB_NAME, DB_HOST);
