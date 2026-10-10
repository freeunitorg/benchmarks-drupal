<?php

declare(strict_types=1);

namespace App\Controller;

use PDO;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Bundle\FrameworkBundle\Controller\AbstractController;
use Symfony\Component\Routing\Attribute\Route;
use Twig\Environment;

/**
 * The measured page: 50 rows of 200 read from MariaDB, rendered by Twig.
 *
 * The connection is opened per request on purpose: that is the classic SAPI
 * pattern under php-fpm, mod_php and FreeUnit alike, and the connection cost
 * is part of what the runtimes differ in.
 */
final class HomeController extends AbstractController {

  #[Route('/', name: 'home', methods: ['GET'])]
  public function home(Request $request, Environment $twig): Response {
    $url = $_ENV['DATABASE_URL'] ?? getenv('DATABASE_URL') ?: '';
    $parts = parse_url($url) ?: [];
    $dsn = sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4',
      $parts['host'] ?? 'db', ltrim($parts['path'] ?? '/drupal_symfony', '/'));
    $pdo = new PDO($dsn, $parts['user'] ?? 'root', $parts['pass'] ?? '');

    $q = (string) $request->query->get('q', '');
    if ($q !== '') {
      $stmt = $pdo->prepare('SELECT id, title FROM symfony_items WHERE title LIKE ? ORDER BY id LIMIT 50');
      $stmt->execute(['%' . $q . '%']);
    }
    else {
      $stmt = $pdo->query('SELECT id, title FROM symfony_items ORDER BY id LIMIT 50');
    }
    $items = $stmt->fetchAll(PDO::FETCH_ASSOC);
    $total = (int) $pdo->query('SELECT COUNT(*) FROM symfony_items')->fetchColumn();

    return new Response($twig->render('home.html.twig', [
      'items' => $items,
      'total' => $total,
      'q' => $q,
    ]));
  }

}
