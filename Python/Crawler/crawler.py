import requests
from bs4 import BeautifulSoup
from urllib.parse import urljoin, urlparse
import graphviz
import re
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s: %(message)s')

class WebCrawler:
    def __init__(self, start_urls, max_depth=3, max_links_per_page=10, max_total_links=500):
        self.start_urls = start_urls
        self.max_depth = max_depth
        self.max_links_per_page = max_links_per_page
        self.max_total_links = max_total_links
        self.visited_urls = set()
        self.graph = self._create_graph()

    def _create_graph(self):
        return graphviz.Digraph('WebCrawler', filename='web_crawler.gv', 
            node_attr={
                'color': 'lightblue2', 
                'style': 'filled',
                'shape': 'oval',
                'fontname': 'Arial',
                'fontsize': '10'
            },
            edge_attr={
                'color': 'black',
                'style': 'solid',
            },
            graph_attr={
                'rankdir': 'TB',  # Top to Bottom
                'splines': 'polyline',  # Einfache gerade Linien
                'ranksep': '3.0',  # Größerer vertikaler Abstand
                'nodesep': '0.3',  # Kleinerer horizontaler Abstand
            })

    def _sanitize_url_for_graphviz(self, url):
        """Sanitize URL for Graphviz node naming"""
        return url.replace(':', '_').replace('/', '_').replace('.', '_')

    def _get_domain(self, url):
        """Extract domain from URL"""
        return urlparse(url).netloc

    def _is_valid_url(self, url, base_url):
        """Check if URL is valid and on the same domain"""
        try:
            parsed_base = urlparse(base_url)
            parsed_url = urlparse(url)
            
            # Ignoriere Fragment-Identifier (#)
            if parsed_url.fragment:
                return False
            
            # Ignoriere leere URLs oder JavaScript-Links
            if not url or url.startswith('javascript:'):
                return False
            
            is_valid = (
                parsed_url.scheme in ['http', 'https'] and
                parsed_base.netloc == parsed_url.netloc and
                not url.endswith(('.pdf', '.jpg', '.png', '.gif', '.css', '.js'))  # Ignoriere Medien und Assets
            )
            
            return is_valid
        except Exception as e:
            logging.error(f"Error validating URL {url}: {e}")
            return False

    def crawl(self):
        """Main crawling method for multiple start URLs"""
        for start_url in self.start_urls:
            self._crawl_recursive(start_url, depth=0, parent_url=None)

        # Render the graph
        self.graph.attr(size='12,12')
        self.graph.view()

    def _crawl_recursive(self, url, depth, parent_url=None):
        # Stop conditions
        if (depth > self.max_depth or 
            url in self.visited_urls or 
            len(self.visited_urls) >= self.max_total_links):
            return

        self.visited_urls.add(url)
        logging.info(f"Crawling: {url} (Depth: {depth})")

        try:
            response = requests.get(url, timeout=5)
            response.raise_for_status()
        except requests.RequestException as e:
            logging.error(f"Error accessing {url}: {e}")
            return

        # Add current URL to graph
        sanitized_current_url = self._sanitize_url_for_graphviz(url)
        self.graph.node(sanitized_current_url, label=url)
        
        # Erzwinge die Ebene basierend auf der Tiefe
        self.graph.attr('edge', len='2.0')  # Längere Kanten für bessere Verteilung
        with self.graph.subgraph(name=f'depth_{depth}') as s:
            s.attr(rank='same')
            s.node(sanitized_current_url)

        # If parent exists, create an edge
        if parent_url:
            sanitized_parent_url = self._sanitize_url_for_graphviz(parent_url)
            self.graph.edge(sanitized_parent_url, sanitized_current_url)

        # Parse links
        soup = BeautifulSoup(response.text, 'html.parser')
        found_links = []
        all_links = soup.find_all('a', href=True)
        
        logging.info(f"Found {len(all_links)} total links on {url}")
        
        for link in all_links:
            absolute_url = urljoin(url, link['href'])
            
            if self._is_valid_url(absolute_url, url):
                if absolute_url not in self.visited_urls:
                    found_links.append(absolute_url)
                    logging.info(f"Valid link found: {absolute_url}")
                else:
                    logging.debug(f"Already visited: {absolute_url}")
            else:
                logging.debug(f"Invalid or external link: {absolute_url}")
            
            if len(found_links) >= self.max_links_per_page:
                logging.info(f"Reached max links per page ({self.max_links_per_page})")
                break

        logging.info(f"Found {len(found_links)} valid links to crawl on {url}")

        # Recursive crawling of found links
        for link in found_links:
            self._crawl_recursive(link, depth + 1, url)

# Example usage
start_urls = [
    "HIER_LINK_REIN"
]

crawler = WebCrawler(start_urls, max_depth=3, max_links_per_page=10)
crawler.crawl()