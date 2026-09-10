<?php
  header('Content-Type: application/json');

  function entry(string $name, string $base_url, string $file): array {
      return [
          'name' => $name,
          'url'  => $base_url,
          'hash' => file_exists($file) ? md5_file($file) : '1',
      ];
  }

  $base = 'http://vortex-assets.local/gamedata';
  $dir  = __DIR__;

  echo json_encode(['hashes' => [
      entry('external_texts', 		"$base/external_flash_texts",  		"$dir/external_flash_texts.json"),
      entry('external_variables', 	"$base/external_variables",    		"$dir/external_variables.json"),
      entry('furnidata',        	"$base/furnidata_xml",             	"$dir/furnidata_xml.xml"),
      entry('figuredata',          	"$base/figuredata",             	"$dir/figuredata.xml"),
      entry('productdata',        	"$base/productdata",           		"$dir/productdata_xml.xml"),
      entry('furnidata_json',       "$base/furnidata_json",           	"$dir/furnidata_json.json"),
      entry('productdata_json',     "$base/productdata_json",           "$dir/productdata_json.json"),
  ]]);