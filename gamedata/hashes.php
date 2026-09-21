<?php
  // The manifest the client fetches before anything else. Two shapes:
  //
  //   /gamedata/hashes            the default language, files at the root of gamedata/
  //   /gamedata/<code>/hashes     one language, texts under gamedata/<code>/ with a root fallback
  //
  // The language form is what `localization.<n>.url` in external_variables points at. The client
  // parses it as a manifest and follows its external_texts entry; handing it a texts file instead
  // parses as a manifest with no entries, and every key then resolves to the empty string with
  // nothing logged anywhere.
  //
  // GameDataResources.isValid() requires external_texts, external_variables, furnidata AND
  // productdata, so those four are always published -- with hash '1' when the file is not on disk,
  // which is why furnidata_xml/productdata_xml still appear here. Dropping one of them does not
  // degrade the manifest, it makes the client reject the whole thing.

  header('Content-Type: application/json');

  $base = 'http://vortex-assets.local/gamedata';
  $dir  = __DIR__;

  // A language code as it may appear in a path: letters, digits and dashes, nothing else. The value
  // comes off a URL and is concatenated into a path below, so this is the guard, not decoration.
  $lang = isset($_GET['lang']) ? (string)$_GET['lang'] : '';
  if ($lang !== '' && !preg_match('/^[A-Za-z0-9-]{1,16}$/', $lang)) {
      $lang = '';
  }

  function entry(string $name, string $base_url, string $file): array {
      return [
          'name' => $name,
          'url'  => $base_url,
          'hash' => file_exists($file) ? md5_file($file) : '1',
      ];
  }

  /**
   * A texts file, taken from the language's directory when it has one and from the root otherwise.
   * A language ships only the keys it translates: the client loads the default file first and
   * merges, so a partial translation is a partial file rather than a broken hotel.
   *
   * Returns null when neither exists -- never advertise a file that is not there, because the
   * client would fetch it and take a 404.
   */
  function texts(string $name, string $base, string $dir, string $lang, string $slug, string $file): ?array {
      if ($lang !== '' && is_file("$dir/$lang/$file")) {
          return entry($name, "$base/$lang/$slug", "$dir/$lang/$file");
      }

      return is_file("$dir/$file") ? entry($name, "$base/$slug", "$dir/$file") : null;
  }

  $entries = [
      // Shared across languages.
      entry('external_variables', 	"$base/external_variables",    		"$dir/external_variables.json"),
      entry('furnidata',        	"$base/furnidata_xml",             	"$dir/furnidata_xml.xml"),
      entry('figuredata',          	"$base/figuredata",             	"$dir/figuredata.xml"),
      entry('productdata',        	"$base/productdata",           		"$dir/productdata_xml.xml"),
      entry('furnidata_json',       "$base/furnidata_json",           	"$dir/furnidata_json.json"),
      entry('productdata_json',     "$base/productdata_json",           "$dir/productdata_json.json"),

      // The texts. external_texts is the base file; the external_text_* ones are that same key
      // store split by domain and loaded after it, so a key present in two of them keeps the value
      // from the one listed last here.
      texts('external_texts',        $base, $dir, $lang, 'external_flash_texts', 'external_flash_texts.json'),
      texts('external_text_catalog', $base, $dir, $lang, 'external_catalog_text', 'external_catalog_text.json'),
      texts('external_text_badges',  $base, $dir, $lang, 'external_badges_text',  'external_badges_text.json'),
  ];

  echo json_encode(['hashes' => array_values(array_filter($entries))]);
